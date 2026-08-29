/// Ready queue of threads.
///
/// Idle thread is not included in the ready queue and is handled separately.
var qready: ThreadList = .{};
/// Idle thread.
var idle: *Thread linksection(pcpu.section) = undefined;
/// Currently running thread.
var current: ?*Thread linksection(pcpu.section) = null;
/// Lock that must be released after new thread has been switched-in.
var pending_unlock: ?*SpinLock linksection(pcpu.section) = null;
/// Counter of disabled preemption on this core.
var preempt_disable_count: usize linksection(pcpu.section) = 0;

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

    // Create a new thread group for the idle thread.
    const group = try urd.task.ThreadGroup.new(allocator, th, 0, 0, 0);
    errdefer group.deref(allocator);
    const handlers = try urd.task.signal.Handlers.new(allocator);
    errdefer handlers.deinit(allocator);

    th.* = .{
        .id = 0,
        .ppid = 0,
        .name = "idle", // TODO: should be unique per core.
        .state = .running,
        .sp = undefined,
        .vmm = vmm,
        .fs = undefined, // filled later on fs subsystem initialization.
        .sigstate = .{ .handlers = handlers },
        .group = group,
    };
    group.addMember(th);
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

    urd.perf.recordThreadName(getCurrent().name);
}

/// Add a thread to the ready queue.
pub fn enqueue(th: *Thread) void {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    th.state = .running;
    qready.append(th);
}

/// Set the CPU affinity mask of a thread.
///
/// Marks the thread as needing rescheduling so that it's immediately migrated to eligible cores.
pub fn setAffinity(th: *Thread, mask: u64) void {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    th.affinity = mask;
    th.need_resched = true;
}

/// Enqueue a thread only if it is currently blocked.
///
/// If the thread is not blocked, nop.
pub fn wake(th: *Thread) void {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    if (th.state == .blocked) {
        th.state = .running;
        qready.append(th);
        markNeedResched();
    }
}

/// Yield the current thread to allow other threads to run.
pub fn reschedule() void {
    rescheduleImpl(null, .running, null);
}

/// Put the current thread to sleep.
///
/// Returns immediately if `woken` is already set.
///
/// Marks the current thread as blocked before switching.
pub fn blockCurrentCheckWoken(woken: *const bool) void {
    rescheduleImpl(null, .blocked, woken);
}

/// Put the current thread to sleep.
///
/// Marks the current thread as blocked before switching.
///
/// The lock is released on return.
pub fn blockCurrent(caller_lock: ?*SpinLock) void {
    rescheduleImpl(caller_lock, .blocked, null);
}

/// Exit the current thread.
pub fn exitCurrent(state: thread.State) noreturn {
    rtt.expect(state == .dead or state == .moribund);

    rescheduleImpl(null, state, null);

    // This thread should not be scheduled again.
    unreachable;
}

/// Check if the current thread needs to be rescheduled and yield if possible.
pub fn shouldReschedule() bool {
    if (pcpu.get(&preempt_disable_count) != 0) return false;
    return if (getCurrentNullable()) |c| c.need_resched else false;
}

/// Disable context switching on this core.
///
/// This does not mask IRQs.
pub fn preemptDisable() void {
    pcpu.ptr(&preempt_disable_count).* += 1;
}

/// Re-enable context switching on this core.
pub fn preemptEnable() void {
    const count = pcpu.ptr(&preempt_disable_count);
    rtt.expect(count.* > 0);
    count.* -= 1;
}

/// Mark the currently running thread as needing rescheduling.
pub fn markNeedResched() void {
    getCurrent().need_resched = true;
}

/// Top of the given thread's kernel stack, or 0 if it has none.
fn kstackTopOf(th: *Thread) usize {
    return if (th.stack) |kstack| @intFromPtr(kstack.ptr) + kstack.len else 0;
}

/// Select the next thread to run and switch to it.
///
/// If the caller lock is provided, it is released after the current thread has been switched-out.
///
/// If `skip` is provided and points to a true value, returns immediately.
fn rescheduleImpl(caller_lock: ?*SpinLock, next_state: thread.State, skip: ?*const bool) void {
    const ie = lock.lockDisableIrq();
    if (caller_lock) |l| rtt.expect(l.isLocked());

    if (skip) |s| if (s.*) {
        return lock.unlockRestoreIrq(ie);
    };

    // Get the next thread from the ready queue eligible to run on this core.
    const core_bit = @as(u64, 1) << @intCast(urd.smp.getLogicalCoreId());
    const next = pickNext();
    if (next == getIdle() and
        next_state == .running and
        getCurrent().affinity & core_bit != 0)
    {
        return lock.unlockRestoreIrq(ie);
    }

    const prev = blk: {
        // Account runtime before switching away from the current thread.
        accountRuntime();

        // Move the current thread to the ready queue.
        const cur = getCurrent();
        cur.state = next_state;
        cur.need_resched = false;
        if (cur.state == .running and cur != getIdle()) {
            qready.append(cur);
        }
        setCurrent(next);

        // Switch user-space page table if needed.
        arch.mmu.switchAddressSpace(next.vmm.as, urd.mem.page);

        // Stash the caller's lock so it can be released after switch-out.
        pcpu.ptr(&pending_unlock).* = caller_lock;

        // Switch to the next thread. IRQs remain disabled.
        break :blk arch.thread.switchContext(
            &cur.sp,
            &next.sp,
            kstackTopOf(next),
            cur,
        );
    };

    {
        // Do deferred work for the previous thread.
        onSwitchedIn(@ptrCast(@alignCast(prev)));

        // Update the last switch-in timestamp.
        updateLastExecTimestamp();
    }

    // Restore IRQ mask.
    arch.intr.setMask(ie);
}

/// Called by a newly switched-in thread when a thread is switched out.
///
/// Do some deferred work for the previous thread.
export fn onSwitchedIn(prev: *Thread) callconv(.c) void {
    // Unlock scheduler and the caller's lock if provided.
    lock.unlock();
    const pending = pcpu.ptr(&pending_unlock);
    if (pending.*) |l| {
        pending.* = null;
        l.unlock();
    }

    // Do deferred work for the previous thread.
    urd.task.onSwitchedOut(prev);

    // Perf recording.
    const cur = getCurrent();
    if (cur.last_exec_start == 0) {
        urd.perf.recordThreadName(cur.name);
    }
    urd.perf.record(.init(.sched_switch, .{}));
}

/// Pick the next thread from the ready queue eligible to run on this core.
///
/// Falls back to the idle thread if no other thread is eligible to run on this core.
fn pickNext() *Thread {
    rtt.expect(lock.isLocked());

    const core_bit = @as(u64, 1) << @intCast(urd.smp.getLogicalCoreId());

    var it = qready.iter();
    while (it.next()) |th| {
        if (th.affinity & core_bit != 0) {
            qready.remove(th);
            return th;
        }
    } else return getIdle();
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
noinline fn getCurrentNullable() ?*Thread {
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
        if (urd.smp.getLogicalCoreId() == 0 and
            getIdle().runtime_us >= options.idle_watchdog * std.time.us_per_s)
        {
            @branchHint(.cold);
            log.warn("Idle thread exceeded pre-defined runtime limit.", .{});
            urd.eol(0);
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
