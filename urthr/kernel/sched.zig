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

/// Timer tick interval in microseconds.
const tick_interval_us: u64 = 10_000;

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
    };
    idle = th;

    // Set the idle thread as the current thread.
    current = idle;

    // Set timer interrupt handler for preemptive scheduling.
    urd.exception.setHandler(arch.timer.ppi_intid, timerHandler) catch {
        @panic("Failed to set timer interrupt handler.");
    };
}

/// Start the preemptive scheduling timer.
pub fn startTimer() !void {
    board.enableIrq(arch.timer.ppi_intid);

    const ticks = (tick_interval_us * arch.timer.getFreq()) / 1_000_000;
    arch.timer.setDeadline(@intCast(ticks));
    arch.timer.enable();
}

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
    th.* = .{
        .id = allocateId(),
        .name = try ga.dupe(u8, name),
        .state = .ready,
        .sp = @intFromPtr(sp.ptr) + sp.len,
        .stack = stack,
    };

    // Add the thread to the ready queue.
    qready.append(th);

    return th;
}

/// Mark the currently running thread as needing rescheduling.
fn markNeedResched() void {
    getCurrent().need_resched = true;
}

/// Timer interrupt handler.
///
/// Re-arms the timer and check if the current thread needs to be rescheduled.
fn timerHandler() void {
    // Re-arm timer for next tick.
    const ticks = (tick_interval_us * arch.timer.getFreq()) / 1_000_000;
    arch.timer.setDeadline(@intCast(ticks));

    // This thread needs to be rescheduled.
    markNeedResched();
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

    // Move the current thread to the ready queue.
    const cur = getCurrent();
    cur.state = .ready;
    cur.need_resched = false;
    if (cur != idle) {
        qready.append(cur);
    }

    current = next;

    // Release lock before switching. IRQs remain disabled until restored.
    lock.unlock();

    // Switch to the next thread.
    arch.thread.switchContext(&cur.sp, &next.sp);

    // Resume here when switched back to this thread.
    arch.intr.setMask(ie);
}

/// Exit the current thread.
///
/// Marks the current thread as dead and switches to the next ready thread.
fn exitCurrentThread() noreturn {
    _ = lock.lockDisableIrq();

    // Mark the current thread as dead.
    const cur = getCurrent();
    cur.state = .dead;

    // Pop the next thread from the ready queue.
    const next = qready.popFirst() orelse idle;
    next.state = .running;
    current = next;

    // Release lock before switching. IRQs remain disabled.
    lock.unlock();

    // Switch to the next thread.
    arch.thread.switchContext(&cur.sp, &next.sp);

    unreachable;
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

/// Create a wrapper struct that provides a thread entry point function.
fn ThreadFuncWrapper(comptime f: anytype, ArgType: type) type {
    return struct {
        pub fn function(argv: *const ArgType) callconv(.c) void {
            // Call function with the provided arguments.
            callThreadFunction(f, argv.*);

            // Destroy arguments.
            urd.mem.getGeneralAllocator().destroy(argv);

            // Exit thread.
            exitCurrentThread();
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
const board = @import("board").impl;
const common = @import("common");
const page_size = common.mem.size_4kib;
const urd = @import("urthr");
const SpinLock = urd.SpinLock;
const thread = urd.thread;
const Thread = thread.Thread;
const ThreadList = thread.ThreadList;
