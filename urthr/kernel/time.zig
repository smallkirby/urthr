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
