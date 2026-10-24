/// Type of kernel timestamp.
pub const Ktimestamp = u64;

/// Initialize the timer subsystem.
pub fn initGlobal() void {
    urd.exception.setHandler(arch.timer.ppi_intid, .{
        .function = timerHandler,
        .ctx = null,
    }) catch {
        @panic("Failed to set timer interrupt handler.");
    };

    // Register sleep checker as a timer callback.
    register(sleep_checker_interval_us, &checkSleepers) catch {
        @panic("Failed to register sleep checker timer callback.");
    };

    // Register itimer checker as a timer callback.
    register(sleep_checker_interval_us, &checkItimers) catch {
        @panic("Failed to register itimer checker timer callback.");
    };

    // Register deadline checker as a timer callback.
    register(deadline_check_interval_us, &checkDeadlines) catch {
        @panic("Failed to register deadline checker timer callback.");
    };
}

/// Initialize the timer for the calling CPU.
///
/// Must be called on each CPU after GIC CPU interface initialization.
pub fn initLocal() void {
    arch.timer.enable();
    armTimer();
    board.enableIrq(arch.timer.ppi_intid);
}

/// Register a periodic timer callback on the calling core.
///
/// The callback will be invoked approximately every `interval_us` microseconds in IRQ context of the calling core.
/// If `interval_us` is zero, the callback is invoked only once at the next timer interrupt.
///
/// No guarantee is made about the exact timing, and callbacks may be delayed if the system is busy.
pub fn register(interval_us: u64, callback: *const fn () void) Allocator.Error!void {
    const entry = try urd.mem.bin.create(Entry);
    errdefer urd.mem.bin.destroy(entry);

    const ie = arch.intr.maskAll();
    defer arch.intr.setMask(ie);

    entry.* = .{
        .interval_us = interval_us,
        .next_us = getCurrentTimestampUs() + interval_us,
        .callback = callback,
    };
    getEntries().append(entry);

    // The new entry may expire earlier than the currently armed deadline.
    armTimer();
}

/// Get the current kernel timestamp in nanoseconds.
pub fn getCurrentTimestamp() Ktimestamp {
    const count: u128 = arch.timer.getCount();
    const freq: u128 = arch.timer.getFreq();
    return @truncate(count * 1_000_000_000 / freq);
}

/// Get the current wall-clock time in nanoseconds since the UNIX epoch.
///
/// TODO: implement wall-clock.
pub fn getRealtime() Ktimestamp {
    return getCurrentTimestamp();
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
    qsleep.append(&entry);

    // The lock is released by the scheduler.
    urd.sched.blockCurrent(&qsleep_lock);

    // Ensure that the entry is no longer linked in the queue.
    {
        const ie_inner = qsleep_lock.lockDisableIrq();
        defer qsleep_lock.unlockRestoreIrq(ie_inner);
        if (!entry.fired) qsleep.remove(&entry);
    }
    arch.intr.setMask(ie);
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
    /// Whether the entry has been removed from the queue.
    fired: bool = false,
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
            entry.fired = true;
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
// Deadline Callbacks
// =============================================================

/// A one-shot callback scheduled to run once a given deadline has expired.
pub const Deadline = struct {
    /// Absolute expiration time in nanoseconds.
    deadline_ns: u64,
    /// Function to invoke once the deadline has expired..
    callback: *const fn (*Deadline) void,
    /// Indicates if the deadline has already fired or been cancelled.
    fired: bool = false,
    /// List head.
    _head: List.Head = .{},

    const List = common.typing.InlineDoublyLinkedList(Deadline, "_head");
};

/// Schedule the callback invoked once the deadline has expired.
pub fn scheduleDeadline(entry: *Deadline) void {
    entry.fired = false;

    const ie = qdeadline_lock.lockDisableIrq();
    defer qdeadline_lock.unlockRestoreIrq(ie);
    qdeadline.append(entry);
}

/// Cancel a previously scheduled deadline.
///
/// Safe to call even if the deadline has already fired.
pub fn cancelDeadline(entry: *Deadline) void {
    const ie = qdeadline_lock.lockDisableIrq();
    defer qdeadline_lock.unlockRestoreIrq(ie);

    if (!entry.fired) {
        qdeadline.remove(entry);
        entry.fired = true;
    }
}

/// Interval for checking deadline callbacks in microseconds.
const deadline_check_interval_us: u64 = 10 * std.time.us_per_ms;

/// Queue of pending deadline callbacks.
var qdeadline: Deadline.List = .{};
/// Spin lock protecting `qdeadline`.
var qdeadline_lock: SpinLock = .{};

/// Run every deadline callback whose expiration has passed.
///
/// Callbacks are called in a hard IRQ context.
fn checkDeadlines() void {
    const ie = qdeadline_lock.lockDisableIrq();
    defer qdeadline_lock.unlockRestoreIrq(ie);

    const now_ns = getCurrentTimestamp();
    var it = qdeadline.iter();
    while (it.next()) |entry| {
        if (now_ns >= entry.deadline_ns) {
            qdeadline.remove(entry);
            entry.fired = true;
            entry.callback(entry);
        }
    }
}

// =============================================================
// Internal
// =============================================================

/// Timer callback entry.
const Entry = struct {
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
/// List of timer callbacks of this core.
var local_entries: EntryList linksection(pcpu.section) = .{};

/// Interval of the timer interrupt in microseconds when no callback is registered.
const idle_interval_us: u64 = 1 * std.time.us_per_s;

/// Get the list of timer callbacks of this core.
inline fn getEntries() *EntryList {
    return pcpu.ptr(&local_entries);
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
/// Dispatches all expired callbacks and arms the timer for the earliest next expiration.
fn timerHandler(_: urd.exception.Vector, _: ?*anyopaque) void {
    const now = getCurrentTimestampUs();
    var it = getEntries().iter();
    while (it.next()) |entry| {
        if (now >= entry.next_us) {
            entry.callback();

            if (entry.interval_us == 0) {
                getEntries().remove(entry);
                urd.mem.bin.destroy(entry);
                continue;
            }

            entry.next_us = @max(entry.next_us + entry.interval_us, now + 1);
        }
    }

    armTimer();
}

/// Arm the timer for the earliest expiration of the callbacks.
///
/// Must be called with IRQ disabled.
fn armTimer() void {
    const now = getCurrentTimestampUs();
    var next = now + idle_interval_us;

    var it = getEntries().iter();
    var first = true;
    while (it.next()) |entry| {
        next = if (first) entry.next_us else @min(next, entry.next_us);
        first = false;
    }

    const delta_us = next -| now;
    const ticks = @max(1, (delta_us * arch.timer.getFreq()) / std.time.us_per_s);
    arch.timer.setDeadline(@intCast(@min(ticks, std.math.maxInt(u32))));
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
const pcpu = urd.pcpu;
const SpinLock = urd.sync.SpinLock;
const Thread = urd.task.thread.Thread;
