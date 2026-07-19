/// Ready queue of threads.
///
/// Idle thread is not included in the ready queue and is handled separately.
var qready: ThreadList = .{};
/// Idle thread.
var idle: *Thread linksection(pcpu.section) = undefined;
/// Currently running thread.
var current: ?*Thread linksection(pcpu.section) = null;

/// Spin lock for scheduler and thread management.
var lock: SpinLock = .{};
/// Thread ID assigned to the next created thread.
var id_next: thread.Id = 1;

pub const Error = error{
    /// Invalid argument provided.
    InvalidArgument,
    /// Memory allocation failed.
    OutOfMemory,
};

/// Initialize the scheduler.
///
/// Currently running context is set to the idle thread.
pub fn initLocal() Allocator.Error!void {
    const allocator = urd.mem.bin;

    // Create the idle thread.
    const th = try allocator.create(Thread);
    errdefer allocator.destroy(th);
    const vmm = try urd.task.Vmm.new(allocator, urd.mem.getKernelPageTable());
    errdefer vmm.deinit(allocator);

    th.* = .{
        .id = 0,
        .tgid = 0,
        .ppid = 0,
        .pgid = 0,
        .sid = 0,
        .name = "idle", // TODO: should be unique per core.
        .state = .running,
        .sp = undefined,
        .vmm = vmm,
        .fs = undefined, // filled later on fs subsystem initialization.
    };
    pcpu.ptr(&idle).* = th;

    // Set the idle thread as the current thread.
    setCurrent(th);
}

/// Start the preemptive scheduling timer.
pub fn start() !void {
    rtt.expectEqual(getIdle(), getCurrent());

    // Register scheduler timer callback.
    _ = try time.register(tick_interval_us, onTimerTick);

    // Initialize idle thread runtime accounting.
    getCurrent().last_exec_start = arch.timer.getCount();
}

/// Add a thread to the ready queue.
pub fn enqueue(th: *Thread) void {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    th.state = .ready;
    qready.append(th);
}

/// Enqueue a thread only if it is currently blocked.
///
/// If the thread is not blocked, nop.
pub fn wake(th: *Thread) void {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    if (th.state == .blocked) {
        th.state = .ready;
        qready.append(th);
        markNeedResched();
    }
}

/// Put the current thread to sleep.
///
/// Returns immediately if `woken` is already set.
///
/// Marks the current thread as blocked before switching.
pub fn blockCurrentCheckWoken(woken: *const bool) void {
    const ie = lock.lockDisableIrq();
    defer arch.intr.setMask(ie);

    // Check if the thread was already woken during the lock is held.
    if (woken.*) {
        lock.unlock();
        return;
    }

    blockCurrentImpl(null);
}

/// Put the current thread to sleep.
///
/// Marks the current thread as blocked before switching.
///
/// The lock is released on return.
pub fn blockCurrent(caller_lock: ?*SpinLock) void {
    const ie = lock.lockDisableIrq();
    defer arch.intr.setMask(ie);

    blockCurrentImpl(caller_lock);
}

/// Put the current thread to sleep and switch to another thread.
fn blockCurrentImpl(caller_lock: ?*SpinLock) void {
    rtt.expect(lock.isLocked());
    if (caller_lock) |l| rtt.expect(l.isLocked());

    // Update the current thread's runtime.
    accountRuntime();

    const cur = getCurrent();
    cur.state = .blocked;
    cur.need_resched = false;

    const next = pickNext();
    setCurrent(next);
    next.state = .running;

    // Switch user-space page table if needed.
    arch.mmu.switchAddressSpace(next.vmm.as, urd.mem.page);

    // Release locks before switching.
    lock.unlock();
    if (caller_lock) |l| l.unlock();

    // Switch to the next thread.
    arch.thread.switchContext(&cur.sp, &next.sp);

    // Update the last switch-in timestamp.
    updateLastExecTimestamp();
}

/// Yield the current thread to allow other threads to run.
///
/// If no other threads are ready, this will simply return and continue running the current thread.
pub fn reschedule() void {
    const ie = lock.lockDisableIrq();

    // Get the next thread from the ready queue.
    const next = qready.popFirst() orelse {
        return lock.unlockRestoreIrq(ie);
    };
    next.state = .running;

    // Account runtime before switching away from the current thread.
    accountRuntime();

    // Move the current thread to the ready queue.
    const cur = getCurrent();
    cur.state = .ready;
    cur.need_resched = false;
    if (cur != getIdle()) {
        qready.append(cur);
    }

    setCurrent(next);

    // Switch user-space page table if needed.
    arch.mmu.switchAddressSpace(next.vmm.as, urd.mem.page);

    // Release lock before switching. IRQs remain disabled until restored.
    lock.unlock();

    // Switch to the next thread.
    arch.thread.switchContext(&cur.sp, &next.sp);

    // Update the last switch-in timestamp.
    updateLastExecTimestamp();

    // Resume here when switched back to this thread.
    arch.intr.setMask(ie);
}

/// Exit the current thread.
///
/// Marks the current thread as dead and switches to the next ready thread.
pub fn exitCurrent() noreturn {
    _ = lock.lockDisableIrq();

    rtt.expect(getCurrent() != getIdle());

    accountRuntime();

    // Mark the current thread as dead.
    const cur = getCurrent();
    cur.state = .dead;

    // Select and set the next thread to run.
    const next = pickNext();
    setCurrent(next);
    next.state = .running;

    // Switch user-space page table if needed.
    arch.mmu.switchAddressSpace(next.vmm.as, urd.mem.page);

    // Release lock before switching. IRQs remain disabled.
    lock.unlock();

    // Switch to the next thread.
    arch.thread.switchContext(&cur.sp, &next.sp);

    // This thread should not be scheduled again.
    unreachable;
}

/// Check if the current thread needs to be rescheduled and yield if possible.
pub fn shouldReschedule() bool {
    return if (getCurrentNullable()) |c| c.need_resched else false;
}

/// Mark the currently running thread as needing rescheduling.
pub fn markNeedResched() void {
    getCurrent().need_resched = true;
}

/// Pick the next thread to run from the ready queue.
///
/// Falls back to the idle thread if the ready queue is empty.
fn pickNext() *Thread {
    return qready.popFirst() orelse getIdle();
}

/// Get the currently running thread.
pub fn getCurrent() *Thread {
    return getCurrentNullable().?;
}

/// Get the ISR context of the current thread.
///
/// Valid only when called from a syscall handler.
pub fn getCurrentCtx() *arch.exception.Context {
    return arch.thread.isrContextOf(getCurrent().stack.?);
}

/// Get the currently running thread, or null if no thread is running.
fn getCurrentNullable() ?*Thread {
    return pcpu.get(&current);
}

/// Set the currently running thread.
fn setCurrent(th: *Thread) void {
    pcpu.ptr(&current).* = th;
}

/// Get the idle thread for this core.
fn getIdle() *Thread {
    return pcpu.get(&idle);
}

// =============================================================
// Timer
// =============================================================

/// Scheduler preemption interval in microseconds.
const tick_interval_us: u64 = 10 * std.time.us_per_ms;

/// Scheduler preemption callback.
fn onTimerTick() void {
    markNeedResched();
    accountRuntime();
    updateLastExecTimestamp();
}

/// Account the runtime of the current thread since the last switch-in.
///
/// This function does not update the last switch-in timestamp.
fn accountRuntime() void {
    const cur = getCurrent();
    const now = arch.timer.getCount();
    const delta_ticks = now - cur.last_exec_start;
    const freq: u64 = arch.timer.getFreq();

    cur.runtime_us += (delta_ticks * std.time.us_per_s) / freq;

    if (options.idle_watchdog != 0) {
        if (urd.smp.getLogicalCoreId()) |id| {
            if (id == 0 and getIdle().runtime_us >= options.idle_watchdog * std.time.us_per_s) {
                @branchHint(.cold);
                log.warn("Idle thread exceeded pre-defined runtime limit.", .{});
                urd.eol(0);
            }
        }
    }
}

/// Update the last execution timestamp for the current thread.
fn updateLastExecTimestamp() void {
    getCurrent().last_exec_start = arch.timer.getCount();
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.sched);
const Allocator = std.mem.Allocator;
const arch = @import("arch").impl;
const options = @import("options");
const common = @import("common");
const rtt = common.rtt;
const page_size = common.mem.size_4kib;
const urd = @import("urthr");
const pcpu = urd.pcpu;
const SpinLock = urd.sync.SpinLock;
const thread = urd.task.thread;
const Thread = thread.Thread;
const ThreadList = thread.ThreadList;
const time = @import("time.zig");
