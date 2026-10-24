/// Type of kernel timestamp.
pub const Ktimestamp = u64;

/// Function invoked when a timer has expired.
///
/// Called in IRQ context with the lock of the timer queue held.
pub const Callback = *const fn (*Timer) void;

/// Initialize the timer subsystem.
pub fn initGlobal() void {
    urd.exception.setHandler(arch.timer.ppi_intid, .{
        .function = timerHandler,
        .ctx = null,
    }) catch {
        @panic("Failed to set timer interrupt handler.");
    };
}

/// Initialize the timer for the calling CPU.
///
/// Must be called on each CPU after interrupt controller initialization.
pub fn initLocal() void {
    // Enable the local timer for this CPU.
    arch.timer.enable();

    // Arm the local timer.
    {
        const ie = arch.intr.maskAll();
        defer arch.intr.setMask(ie);

        const timer = getLocalTimer();
        timer.lock.lock();
        defer timer.lock.unlock();

        armTimerLocked(timer);
    }

    // Enable IRQ for the local timer.
    board.enableIrq(arch.timer.ppi_intid);
}

/// Timer instance.
pub const Timer = struct {
    /// Absolute expiration time in nanoseconds.
    deadline_ns: u64,
    /// Function to invoke once the timer has expired.
    callback: Callback,
    /// Reload interval in nanoseconds.
    ///
    /// If non-zero, the timer is re-queued after expiration.
    /// If zero, the timer is one-shot.
    interval_ns: u64 = 0,
    /// Indicates if the timer has already fired or been cancelled.
    fired: bool = false,
    /// Logical ID of the core whose queue this timer is queued.
    cpu: usize = 0,

    /// List head.
    _head: List.Head = .{},

    const List = InlineDoublyLinkedList(Timer, "_head");
};

/// Register a periodic callback on the calling core.
///
/// The callback will be invoked approximately every `interval_us` microseconds in IRQ context of the calling core.
/// The callback cannot be cancelled.
///
/// No guarantee is made about the exact timing,
/// and callbacks may be delayed if the system is busy.
pub fn schedulePeriodic(interval_us: u64, callback: Callback) Allocator.Error!void {
    const timer = try urd.mem.bin.create(Timer);
    const interval_ns = interval_us * std.time.ns_per_us;
    timer.* = .{
        .deadline_ns = getTimestampAfter(interval_ns),
        .callback = callback,
        .interval_ns = interval_ns,
    };
    scheduleTimer(timer);
}

/// Queue the timer on the calling core.
///
/// The timer is periodic if `interval_ns` is non-zero, and one-shot otherwise.
/// The callback will be invoked in IRQ context of the calling core.
///
/// No guarantee is made about the exact timing,
/// and callbacks may be delayed if the system is busy.
pub fn scheduleTimer(entry: *Timer) void {
    const ie = arch.intr.maskAll();
    defer arch.intr.setMask(ie);

    const timer = getLocalTimer();
    timer.lock.lock();
    defer timer.lock.unlock();

    scheduleLocked(timer, entry);
}

/// Cancel a previously scheduled timer.
///
/// Safe to call from any core and even if the timer has already fired.
///
/// Returns false if the timer is not queued.
pub fn cancelTimer(entry: *Timer) bool {
    const ie = arch.intr.maskAll();
    defer arch.intr.setMask(ie);

    const timer = &core_timers[entry.cpu];
    timer.lock.lock();
    defer timer.lock.unlock();

    if (entry.fired) {
        return false;
    } else {
        timer.queue.remove(entry);
        entry.fired = true;
        return true;
    }
}

/// Blocks the calling thread until the specified duration has passed.
///
/// It is ensured that the calling thread is blocked at least until the specified duration.
pub fn sleepUs(duration_us: u64) void {
    var entry: SleepEntry = .{
        .thread = urd.sched.getCurrent(),
        .timer = .{
            .deadline_ns = getTimestampAfter(duration_us * std.time.ns_per_us),
            .callback = wakeSleeper,
        },
    };

    const ie = arch.intr.maskAll();
    defer arch.intr.setMask(ie);
    const timer = getLocalTimer();
    timer.lock.lock();
    scheduleLocked(timer, &entry.timer);

    // The lock is released by the scheduler.
    urd.sched.blockCurrent(&timer.lock);

    // Ensure that the entry is no longer linked in the queue.
    _ = cancelTimer(&entry.timer);
}

/// Get the current kernel timestamp in nanoseconds.
pub fn getCurrentTimestamp() Ktimestamp {
    const count: u64 = arch.timer.getCount();
    const freq: u64 = arch.timer.getFreq();

    const sec = count / freq;
    const rem = count % freq;
    return sec * std.time.ns_per_s + rem * std.time.ns_per_s / freq;
}

/// Get the current wall-clock time in nanoseconds since the UNIX epoch.
///
/// TODO: implement wall-clock.
pub fn getRealtime() Ktimestamp {
    return getCurrentTimestamp();
}

/// Get the timestamp after the specified duration in nanoseconds.
inline fn getTimestampAfter(ns: u64) Ktimestamp {
    return getCurrentTimestamp() + ns;
}

// =============================================================
// Internal
// =============================================================

/// Timer state of a single core.
const CoreTimer = struct {
    /// Lock protecting `queue`.
    lock: SpinLock = .{},
    /// Pending timers.
    queue: Timer.List = .{},
};

/// Timer state of all cores.
var core_timers: [board.num_cpus]CoreTimer = @splat(.{});

/// Get the timer state of the calling core.
///
/// IRQ must be disabled.
fn getLocalTimer() *CoreTimer {
    return &core_timers[urd.smp.getLogicalCoreId()];
}

/// Queue the timer on the given core's timer queue, and arm the local timer.
///
/// Must be called with IRQ disabled and the lock of the timer held.
fn scheduleLocked(timer: *CoreTimer, entry: *Timer) void {
    entry.fired = false;
    entry.cpu = urd.smp.getLogicalCoreId();
    timer.queue.append(entry);

    armTimerLocked(timer);
}

/// Arm the timer of the calling core for the earliest expiration of its queue.
///
/// Must be called with IRQ disabled and the lock of the timer held.
fn armTimerLocked(timer: *CoreTimer) void {
    // TODO: should use tree to efficiently find the earliest timer.
    var next: ?u64 = null;
    var it = timer.queue.iter();
    while (it.next()) |entry| {
        next = @min(next orelse entry.deadline_ns, entry.deadline_ns);
    }

    // Stop periodic timer if no timers are pending.
    const deadline = next orelse return arch.timer.cancelDeadline();

    // Re-arm the timer for the next expiration.
    const ticks = nsToTicks(deadline -| getCurrentTimestamp());
    arch.timer.setDeadline(@intCast(
        std.math.clamp(ticks, 1, std.math.maxInt(u32)),
    ));
}

/// Convert nanoseconds to ticks of the timer without overflow.
inline fn nsToTicks(ns: u64) u64 {
    const freq: u64 = arch.timer.getFreq();
    const sec = ns / std.time.ns_per_s;
    const sub_sec = ns % std.time.ns_per_s;
    const ticks_sec = sec *| freq;
    const ticks_sub_sec = sub_sec * freq / std.time.ns_per_s;

    return ticks_sec +| ticks_sub_sec;
}

/// Timer interrupt handler called in IRQ context.
///
/// Runs all expired timer's callbacks and arms the timer for the earliest next expiration.
fn timerHandler(_: urd.exception.Vector, _: ?*anyopaque) void {
    const timer = getLocalTimer();
    timer.lock.lock();
    defer timer.lock.unlock();

    const now = getCurrentTimestamp();
    var it = timer.queue.iter();
    while (it.next()) |entry| {
        if (now < entry.deadline_ns) continue;

        timer.queue.remove(entry);
        entry.fired = true;

        const interval = entry.interval_ns;
        entry.callback(entry);

        if (interval != 0) {
            entry.deadline_ns = now + interval;
            entry.fired = false;
            timer.queue.append(entry);
        }
    }

    armTimerLocked(timer);
}

/// Sleep entry for a thread waiting on a timer.
///
/// Allocated on the sleeping thread's kernel stack.
const SleepEntry = struct {
    /// Sleeping thread waiting on a timer.
    thread: *Thread,
    /// Deadline timer.
    timer: Timer,
};

/// Wake the thread whose sleep deadline has passed.
fn wakeSleeper(timer: *Timer) void {
    const entry: *SleepEntry = @fieldParentPtr("timer", timer);
    rtt.expectEqual(.blocked, entry.thread.state);

    urd.sched.enqueue(entry.thread);
    urd.sched.markNeedResched();
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
const InlineDoublyLinkedList = common.typing.InlineDoublyLinkedList;
const urd = @import("urthr");
const SpinLock = urd.sync.SpinLock;
const Thread = urd.task.thread.Thread;
