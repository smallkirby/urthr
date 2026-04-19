/// Ready queue of threads.
var qready: ThreadList = .{};
/// Idle thread.
var idle: *Thread = undefined;
/// Currently running thread.
var current: ?*Thread = null;

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
pub fn init() Allocator.Error!void {
    const allocator = urd.mem.getGeneralAllocator();

    // Create the idle thread.
    const th = try allocator.create(Thread);
    errdefer allocator.destroy(th);
    th.* = .{
        .id = 0,
        .name = "idle",
        .state = .running,
        .sp = undefined,
        .mm = urd.mem.getKernelPageTable(),
        .fs = undefined, // filled later on fs subsystem initialization.
    };
    idle = th;

    // Set the idle thread as the current thread.
    current = idle;
}

/// Start the preemptive scheduling timer.
pub fn start() !void {
    // Register scheduler timer callback.
    _ = try time.register(tick_interval_us, onTimerTick);

    // Initialize idle thread runtime accounting.
    idle.last_exec_start = arch.timer.getCount();
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
pub fn blockCurrent(caller_lock: *SpinLock) void {
    const ie = lock.lockDisableIrq();

    // Update the current thread's runtime.
    accountRuntime();

    const cur = getCurrent();
    cur.state = .blocked;
    cur.need_resched = false;

    const next = pickNext();
    current = next;
    next.state = .running;

    // Switch user-space page table if needed.
    arch.mmu.switchUserTable(next.mm.l0, urd.mem.getPageAllocator());

    lock.unlock();
    caller_lock.unlock();

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
    if (cur != idle) {
        qready.append(cur);
    }

    current = next;

    // Switch user-space page table if needed.
    arch.mmu.switchUserTable(next.mm.l0, urd.mem.getPageAllocator());

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

    accountRuntime();

    // Mark the current thread as dead.
    const cur = getCurrent();
    cur.state = .dead;

    // Select and set the next thread to run.
    const next = pickNext();
    current = next;
    next.state = .running;

    // Switch user-space page table if needed.
    arch.mmu.switchUserTable(next.mm.l0, urd.mem.getPageAllocator());

    // Release lock before switching. IRQs remain disabled.
    lock.unlock();

    // Switch to the next thread.
    arch.thread.switchContext(&cur.sp, &next.sp);

    // This thread should not be scheduled again.
    unreachable;
}

/// Check if the current thread needs to be rescheduled and yield if possible.
pub fn shouldReschedule() bool {
    return getCurrent().need_resched;
}

/// Mark the currently running thread as needing rescheduling.
pub fn markNeedResched() void {
    getCurrent().need_resched = true;
}

/// Pick the next thread to run from the ready queue.
///
/// Falls back to the idle thread if the ready queue is empty.
fn pickNext() *Thread {
    return qready.popFirst() orelse idle;
}

/// Get the currently running thread.
pub fn getCurrent() *Thread {
    return current.?;
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
        if (idle.runtime_us >= options.idle_watchdog * std.time.us_per_s) {
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
// Thread entry point wrapper.
// =============================================================

/// Spawn a new thread with the given entry function and arguments.
///
/// Entry function can have any signature.
/// The arguments are copied and passed to the entry function.
pub fn spawn(name: []const u8, entry: anytype, args: anytype) Error!*Thread {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    const ga = urd.mem.getGeneralAllocator();
    const pa = urd.mem.getPageAllocator();

    const th = try ga.create(Thread);
    errdefer ga.destroy(th);

    // Copy arguments.
    const argv = try ga.create(@TypeOf(args));
    errdefer ga.destroy(argv);
    argv.* = args;

    // Define thread wrapper function.
    const Wrapper = ThreadFuncWrapper(entry, @TypeOf(args));

    // Initialize stack.
    const stack_size = thread.default_stack_size;
    const stack = try pa.allocPagesV(stack_size / page_size);
    errdefer pa.freePagesV(stack);
    const sp = arch.thread.initStack(
        stack,
        &Wrapper.function,
        argv,
    );

    // Initialize thread.
    const fs = getCurrent().fs;
    fs.root.dentry.ref();
    errdefer fs.root.dentry.unref();
    fs.cwd.dentry.ref();
    errdefer fs.cwd.dentry.unref();
    th.* = .{
        .id = allocateId(),
        .name = try ga.dupe(u8, name),
        .state = .ready,
        .sp = @intFromPtr(sp.ptr) + sp.len,
        .stack = stack,
        .mm = urd.mem.getKernelPageTable(),
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
            urd.mem.getGeneralAllocator().destroy(argv);

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
const page_size = common.mem.size_4kib;
const urd = @import("urthr");
const SpinLock = urd.SpinLock;
const thread = urd.thread;
const Thread = thread.Thread;
const ThreadList = thread.ThreadList;
const time = @import("time.zig");
