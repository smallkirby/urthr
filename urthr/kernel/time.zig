/// Type of kernel timestamp.
pub const Ktimestamp = u64;

/// Timer callback ID.
///
/// Used to unregister a callback.
pub const Id = u32;

/// Lock to protect the event list.
var lock: SpinLock = .{};

/// Initialize the timer subsystem.
pub fn initGlobal() void {
    urd.exception.setHandler(arch.timer.ppi_intid, timerHandler) catch {
        @panic("Failed to set timer interrupt handler.");
    };
}

/// Initialize the timer for the calling CPU.
///
/// Must be called on each CPU after GIC CPU interface initialization.
pub fn initLocal() void {
    arch.timer.enable();
    armTimer();
    board.enableIrq(arch.timer.ppi_intid);

    // Register sleep checker as a timer callback.
    _ = register(sleep_checker_interval_us, &checkSleepers) catch {
        @panic("Failed to register sleep checker timer callback.");
    };

    // Register itimer checker as a timer callback.
    _ = register(sleep_checker_interval_us, &checkItimers) catch {
        @panic("Failed to register itimer checker timer callback.");
    };
}

/// Register a periodic timer callback.
///
/// The callback will be invoked approximately every `interval_us` microseconds.
/// No guarantee is made about the exact timing, and callbacks may be delayed if the system is busy.
///
/// Returns an ID that can be used to unregister the callback.
pub fn register(interval_us: u64, callback: *const fn () void) Allocator.Error!Id {
    const allocator = urd.mem.bin;
    const entry = try allocator.create(Entry);
    errdefer allocator.destroy(entry);

    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    entry.* = .{
        .id = allocateId(),
        .interval_us = interval_us,
        .next_us = getCurrentTimestampUs() + interval_us,
        .callback = callback,
    };
    entries.append(entry);

    return entry.id;
}

/// Unregister a previously registered timer callback.
pub fn unregister(id: Id) void {
    const allocator = urd.mem.bin;
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    var it = entries.iter();
    while (it.next()) |entry| {
        if (entry.id == id) {
            entries.remove(entry);
            allocator.destroy(entry);
            return;
        }
    }
}

/// Get the current kernel timestamp in nanoseconds.
pub fn getCurrentTimestamp() Ktimestamp {
    const count: u128 = arch.timer.getCount();
    const freq: u128 = arch.timer.getFreq();
    return @truncate(count * 1_000_000_000 / freq);
}

// =============================================================
// Sleep Queue
// =============================================================

/// Blocks the calling thread until the specified duration has passed.
pub fn sleepUs(duration_us: u64) void {
    var entry: SleepEntry = .{
        .thread = urd.sched.getCurrent(),
        .deadline_ns = getCurrentTimestamp() + duration_us * std.time.ns_per_us,
    };

    const ie = qsleep_lock.lockDisableIrq();
    defer qsleep_lock.unlockRestoreIrq(ie);
    qsleep.append(&entry);

    urd.sched.blockCurrent(&qsleep_lock);
}

/// Interval for checking sleeping threads in microseconds.
const sleep_checker_interval_us: u64 = 10 * std.time.us_per_ms;

/// Queue of sleeping threads.
var qsleep: SleepEntry.List = .{};
/// Spin lock to protect the sleep queue.
var qsleep_lock: SpinLock = .{};

/// Sleep entry for a thread waiting on a timer.
///
/// Allocated on the sleeping thread's kernel stack.
const SleepEntry = struct {
    /// Sleeping thread waiting on a timer.
    thread: *Thread,
    /// Absolute wake-up time in nanoseconds.
    deadline_ns: u64,
    /// List head.
    _head: List.Head = .{},

    /// List type for sleep entries.
    const List = common.typing.InlineDoublyLinkedList(SleepEntry, "_head");
};

/// Wake threads whose sleep deadline has passed.
///
/// Runs as a timer callback in IRQ context.
fn checkSleepers() void {
    const ie = qsleep_lock.lockDisableIrq();
    defer qsleep_lock.unlockRestoreIrq(ie);

    const now_ns = getCurrentTimestamp();
    var woke_any = false;

    var iter = qsleep.iter();
    while (iter.next()) |entry| {
        if (now_ns >= entry.deadline_ns) {
            rtt.expectEqual(.blocked, entry.thread.state);
            rtt.expect(qsleep.len > 0);

            qsleep.remove(entry);
            urd.sched.enqueue(entry.thread);

            woke_any = true;
        }
    }

    if (woke_any) urd.sched.markNeedResched();
}

// =============================================================
// Interval Timers
// =============================================================

/// Setting of an interval timer in nanoseconds.
pub const ItimerValue = struct {
    /// Time remaining until the next expiration.
    ///
    /// Zero if disarmed.
    value_ns: u64,
    /// Reload interval for periodic expirations.
    ///
    /// Zero for a one-shot timer.
    interval_ns: u64,
};

/// Arm, re-arm, or disarm the given thread's real-time interval timer.
///
/// A `value_ns` of zero disarms the timer.
/// Returns the setting that was replaced.
pub fn setItimer(thread: *Thread, value_ns: u64, interval_ns: u64) ItimerValue {
    const allocator = urd.mem.bin;
    const now_ns = getCurrentTimestamp();

    const ie = qitimer_lock.lockDisableIrq();
    defer qitimer_lock.unlockRestoreIrq(ie);

    // Check if the thread already has an armed timer to remove it.
    var old: ItimerValue = .{ .value_ns = 0, .interval_ns = 0 };
    var it = qitimer.iter();
    while (it.next()) |entry| {
        if (entry.thread == thread) {
            old = .{
                .value_ns = if (entry.deadline_ns > now_ns) entry.deadline_ns - now_ns else 0,
                .interval_ns = entry.interval_ns,
            };
            qitimer.remove(entry);
            allocator.destroy(entry);
            break;
        }
    }

    if (value_ns != 0) {
        const entry = allocator.create(ItimerEntry) catch @panic("Failed to allocate itimer entry.");
        entry.* = .{
            .thread = thread,
            .deadline_ns = now_ns + value_ns,
            .interval_ns = interval_ns,
        };
        qitimer.append(entry);
    }

    return old;
}

/// Disarm the given thread's interval timer, discarding any pending expiration.
pub fn cancelItimer(thread: *Thread) void {
    _ = setItimer(thread, 0, 0);
}

/// Queue of armed interval timers.
var qitimer: ItimerEntry.List = .{};
/// Spin lock to protect the itimer queue.
var qitimer_lock: SpinLock = .{};

/// An armed interval timer for a single thread.
const ItimerEntry = struct {
    /// Thread that owns this timer.
    thread: *Thread,
    /// Absolute expiration time in nanoseconds.
    deadline_ns: u64,
    /// Reload interval in nanoseconds.
    ///
    /// Zero for a one-shot timer.
    interval_ns: u64,
    /// List head.
    _head: List.Head = .{},

    /// List type for itimer entries.
    const List = common.typing.InlineDoublyLinkedList(ItimerEntry, "_head");
};

/// Deliver a signal to threads whose interval timer has expired.
///
/// Runs as a timer callback in IRQ context.
fn checkItimers() void {
    const ie = qitimer_lock.lockDisableIrq();
    defer qitimer_lock.unlockRestoreIrq(ie);

    const now_ns = getCurrentTimestamp();
    var it = qitimer.iter();
    while (it.next()) |entry| {
        if (now_ns >= entry.deadline_ns) {
            urd.task.signal.pushTo(entry.thread, .alarm);

            if (entry.interval_ns != 0) {
                entry.deadline_ns = now_ns + entry.interval_ns;
            } else {
                qitimer.remove(entry);
                urd.mem.bin.destroy(entry);
            }
        }
    }
}

// =============================================================
// Internal
// =============================================================

/// Timer callback entry.
const Entry = struct {
    /// Unique ID of the timer callback.
    id: Id,
    /// Interval of the timer callback in microseconds.
    interval_us: u64,
    /// Next scheduled time for the timer callback in microseconds.
    next_us: u64,
    /// Callback function to be invoked when the timer expires.
    callback: *const fn () void,
    /// List head.
    head: EntryList.Head = .{},
};

/// List type for timer callback entries.
const EntryList = common.typing.InlineDoublyLinkedList(Entry, "head");
/// List of timer callbacks.
var entries: EntryList = .{};
/// Next unique ID to assign to a timer callback.
var id_next: Id = 1;

/// Base timer tick interval in microseconds.
const tick_interval_us: u64 = 5 * std.time.us_per_ms;

/// Allocate a new unique ID for a timer entries.
fn allocateId() Id {
    const id = id_next;
    id_next +%= 1;
    return id;
}

/// Get the current kernel timestamp in microseconds.
fn getCurrentTimestampUs() Ktimestamp {
    const count: u128 = arch.timer.getCount();
    const freq: u128 = arch.timer.getFreq();
    return @truncate(count * std.time.us_per_s / freq);
}

/// Timer interrupt handler.
///
/// Called in IRQ context.
///
/// Re-arms the timer and dispatches all due callbacks.
fn timerHandler(_: urd.exception.Vector) void {
    armTimer();

    const now_us = getCurrentTimestampUs();
    var it = entries.iter();
    while (it.next()) |entry| {
        if (now_us >= entry.next_us) {
            entry.callback();
            entry.next_us += entry.interval_us;
        }
    }
}

/// Re-arm the timer for the next tick.
fn armTimer() void {
    const ticks = (tick_interval_us * arch.timer.getFreq()) / std.time.us_per_s;
    arch.timer.setDeadline(@intCast(ticks));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const arch = @import("arch").impl;
const board = @import("board").impl;
const common = @import("common");
const rtt = common.rtt;
const urd = @import("urthr");
const SpinLock = urd.sync.SpinLock;
const Thread = urd.task.thread.Thread;
