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

/// Put the current thread to sleep and release the given lock.
///
/// Marks the current thread as blocked before switching.
///
/// The lock is released before switching.
/// IRQs remain disabled when the thread resumes.
pub fn blockCurrent(caller_lock: ?*SpinLock) void {
    const ie = lock.lockDisableIrq();

    // Update the current thread's runtime.
    accountRuntime();

    const cur = getCurrent();
    cur.state = .blocked;
    cur.need_resched = false;

    const next = pickNext();
    setCurrent(next);
    next.state = .running;

    // Switch user-space page table if needed.
    arch.mmu.switchUserTable(next.vmm.pgtbl.l0, urd.mem.page);

    lock.unlock();
    if (caller_lock) |l| l.unlock();

    arch.thread.switchContext(&cur.sp, &next.sp);

    arch.intr.setMask(ie);

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
    arch.mmu.switchUserTable(next.vmm.pgtbl.l0, urd.mem.page);

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
fn exitCurrent() noreturn {
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
    arch.mmu.switchUserTable(next.vmm.pgtbl.l0, urd.mem.page);

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

/// Allocate a new thread ID.
fn allocateId() thread.Id {
    const id = id_next;
    id_next +%= 1;

    return id;
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
// Thread entry point wrapper.
// =============================================================

/// Spawn a new thread with the given entry function and arguments.
///
/// Entry function can have any signature.
/// The arguments are copied and passed to the entry function.
pub fn spawn(name: []const u8, entry: anytype, args: anytype) Error!*Thread {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    const th = try urd.mem.bin.create(Thread);
    errdefer urd.mem.bin.destroy(th);

    // Copy arguments.
    const argv = try urd.mem.bin.create(@TypeOf(args));
    errdefer urd.mem.bin.destroy(argv);
    argv.* = args;

    // Define thread wrapper function.
    const Wrapper = ThreadFuncWrapper(entry, @TypeOf(args));

    // Initialize stack.
    const stack_size = thread.default_stack_size;
    const stack = try urd.mem.page.allocPagesV(stack_size / page_size);
    errdefer urd.mem.page.freePagesV(stack);
    const sp = arch.thread.initStack(
        stack,
        &Wrapper.function,
        argv,
    );

    // Create user-space page table.
    const vmm = try urd.task.Vmm.new(urd.mem.bin, urd.mem.getKernelPageTable());
    errdefer vmm.deinit(urd.mem.bin);

    // Initialize thread.
    var fs = getCurrent().fs;
    fs.root.dentry.ref();
    errdefer fs.root.dentry.unref();
    fs.cwd.dentry.ref();
    errdefer fs.cwd.dentry.unref();
    fs.fdtbl = .{};

    th.* = .{
        .id = allocateId(),
        .name = try urd.mem.bin.dupe(u8, name),
        .state = .ready,
        .sp = @intFromPtr(sp.ptr) + sp.len,
        .stack = stack,
        .vmm = vmm,
        .fs = fs,
    };

    // Add the thread to the ready queue.
    qready.append(th);

    return th;
}

/// Create a wrapper struct that provides a thread entry point function.
fn ThreadFuncWrapper(comptime f: anytype, ArgType: type) type {
    return struct {
        pub fn function(argv: *const ArgType) callconv(.c) void {
            // Call function with the provided arguments.
            callThreadFunction(f, argv.*);

            // Destroy arguments.
            urd.mem.bin.destroy(argv);

            // Exit thread.
            exitCurrent();
        }
    };
}

/// Call a function with the given anytype argument.
fn callThreadFunction(comptime f: anytype, args: anytype) void {
    switch (@typeInfo(@typeInfo(@TypeOf(f)).@"fn".return_type.?)) {
        .void, .noreturn => {
            @call(.never_inline, f, args);
        },
        .error_union => |info| {
            switch (info.payload) {
                void, noreturn => {
                    @call(.never_inline, f, args) catch |err| {
                        std.log.scoped(.thread).err(
                            "Thread returned error: {s}",
                            .{@errorName(err)},
                        );
                        @panic("Panic.");
                    };
                },
                else => @compileError("Kernel thread function cannot return value."),
            }
        },
        else => @compileError("Kernel thread function cannot return value."),
    }
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
const SpinLock = urd.SpinLock;
const thread = urd.task.thread;
const Thread = thread.Thread;
const ThreadList = thread.ThreadList;
const time = @import("time.zig");
