//! Process and thread module.

pub const thread = @import("task/thread.zig");
pub const Vmm = @import("task/Vmm.zig");

pub const Error = error{
    /// Invalid argument provided.
    InvalidArgument,
    /// Memory allocation failed.
    OutOfMemory,
} || loader.Error;

/// The number of pages allocated for user stack.
const num_stack_pages = 32;
/// Base address of the user stack.
const stack_base = 0x7FFF_FF00_0000;

/// Spin lock for scheduler and thread management.
var lock: SpinLock = .{};
/// Thread ID assigned to the next created thread.
var id_next: thread.Id = 1;

/// Spawn a new kernel thread with the given entry function and arguments.
///
/// Entry function can have any signature.
/// The arguments are copied and passed to the entry function.
///
/// Spawned thread does not have a user context.
pub fn kspawn(filename: []const u8, entry: anytype, args: anytype) Error!*Thread {
    const cur = sched.getCurrent();
    const th = try mem.bin.create(Thread);
    errdefer mem.bin.destroy(th);
    const name = try mem.bin.dupe(u8, filename);
    errdefer mem.bin.free(name);

    // Copy arguments.
    const argv = try mem.bin.create(@TypeOf(args));
    errdefer mem.bin.destroy(argv);
    argv.* = args;

    // Define thread wrapper function.
    const Wrapper = ThreadFuncWrapper(entry, @TypeOf(args));

    // Initialize stack.
    const stack_size = thread.default_stack_size;
    const stack = try mem.page.allocBytesV(stack_size);
    errdefer mem.page.freeBytesV(stack);
    const sp = arch.thread.initStack(
        stack,
        &Wrapper.function,
        argv,
    );

    // Create user-space page table.
    const vmm = try Vmm.new(mem.bin, mem.getKernelPageTable());
    errdefer vmm.deinit(mem.bin);

    // =============================================================
    // No error can be returned after this point.

    // Initialize FS.
    const fs = blk: {
        var fs = cur.fs;
        fs.root.dentry.ref();
        fs.cwd.dentry.ref();
        fs.fdtbl = .{};
        break :blk fs;
    };

    // Initialize thread.
    const id = allocateId();
    th.* = .{
        .id = id,
        .tgid = id,
        .ppid = cur.tgid,
        .pgid = id,
        .sid = id,
        .name = name,
        .state = .ready,
        .sp = @intFromPtr(sp.ptr) + sp.len,
        .stack = stack,
        .vmm = vmm,
        .fs = fs,
    };

    // Add the thread to the ready queue.
    sched.enqueue(th);

    return th;
}

/// Replace the current user process image with a new executable.
pub fn execve(
    filename: []const u8,
    args: []const []const u8,
    envs: []const []const u8,
) Error!void {
    const current = sched.getCurrent();
    const allocator = mem.bin;
    const name = try allocator.dupe(u8, filename);
    errdefer allocator.free(name);

    // Deep-copy arguments.
    const argv = try allocator.dupe([]const u8, args);
    for (argv, 0..) |*arg, i| {
        arg.* = try allocator.dupe(u8, args[i]);
    }
    const envp = try allocator.dupe([]const u8, envs);
    for (envp, 0..) |*env, i| {
        env.* = try allocator.dupe(u8, envs[i]);
    }

    // Replace VM.
    const old_vm = current.vmm;
    const new_vm = try Vmm.new(allocator, mem.getKernelPageTable());
    current.vmm = new_vm;
    arch.mmu.switchUserTable(new_vm.pgtbl.l0, mem.page);
    // Rollback VM on failure.
    errdefer {
        current.vmm = old_vm;
        arch.mmu.switchUserTable(old_vm.pgtbl.l0, mem.page);
        new_vm.deinit(allocator);
    }

    // Setup user image.
    const uimg = try setupUserImage(
        current,
        name,
        argv,
        envp,
    );

    // =============================================================
    // No error can be returned after this point.

    // Clean up memories.
    allocator.free(name);
    for (argv) |arg| {
        allocator.free(arg);
    }
    allocator.free(argv);
    for (envp) |env| {
        allocator.free(env);
    }
    allocator.free(envp);

    // Set thread pointer.
    arch.thread.setThreadPointer(uimg.tp);

    // Old VM is no longer needed.
    old_vm.deinit(allocator);

    // Wake up the parent waiting on a vfork-clone.
    if (current.vfork_done) |vd| {
        current.vfork_done = null;
        vd.complete();
    }

    // Enter userland.
    // Kernel stack is reset to the initial state.
    const kstack = current.stack.?;
    arch.thread.enterUserland(
        uimg.entry,
        uimg.sp,
        @intFromPtr(kstack.ptr) + kstack.len,
    );

    unreachable;
}

/// Enter userland by loading the specified executable.
///
/// This function does not return on success.
pub fn enterUser(
    filename: []const u8,
    args: []const []const u8,
    envs: []const []const u8,
) !noreturn {
    const current = sched.getCurrent();
    const allocator = mem.bin;

    // Initialize stdin.
    const tty = try urd.fs.open("/dev/tty", allocator);
    defer tty.unref();
    _ = try current.fs.fdtbl.set(0, tty);

    // Initialize stdout and stderr.
    const console = try urd.fs.open("/dev/console", allocator);
    defer console.unref();
    _ = try current.fs.fdtbl.set(1, console);
    _ = try current.fs.fdtbl.set(2, console);

    // Setup user image.
    const uimg = try setupUserImage(
        current,
        filename,
        args,
        envs,
    );

    // Set thread pointer.
    arch.thread.setThreadPointer(uimg.tp);

    // Enter userland.
    const kstack = current.stack.?;
    arch.thread.enterUserland(
        uimg.entry,
        uimg.sp,
        @intFromPtr(kstack.ptr) + kstack.len,
    );

    unreachable;
}

/// Flags for thread cloning.
pub const CloneFlags = packed struct {
    /// Shares the same address space.
    vm: bool,
    /// Suspend the parent thread until the child thread exits.
    suspend_parent: bool,
};

/// Clone the current thread.
pub fn clone(flags: CloneFlags, stack: usize) Error!*Thread {
    const th = try mem.bin.create(Thread);
    errdefer mem.bin.destroy(th);
    const cur = sched.getCurrent();
    const name = try mem.bin.dupe(u8, cur.name);
    errdefer mem.bin.free(name);

    // Initialize kernel stack with a copy of the parent's ISR context.
    const kstack = try mem.page.allocBytesV(thread.default_stack_size);
    errdefer mem.page.freeBytesV(kstack);
    const usp = if (stack != 0)
        stack
    else
        arch.thread.getUserStackPointer();
    const sp = arch.thread.initStackFork(
        kstack,
        sched.getCurrentCtx(),
        usp,
    );

    // Share or copy VM.
    const vmm = if (flags.vm)
        cur.vmm.ref()
    else
        cur.vmm.clone(mem.bin) catch return Error.OutOfMemory;
    errdefer vmm.deinit(mem.bin);

    // =============================================================
    // No error can be returned after this point.

    // Copy fs information and fd table.
    const fs = blk: {
        var fs = cur.fs;
        fs.root.dentry.ref();
        fs.cwd.dentry.ref();
        fs.fdtbl = cur.fs.fdtbl.clone();
        break :blk fs;
    };

    // Completion the child signals on exit or execve.
    var vforkw: VforkWaiter = .{};

    // Initialize thread struct.
    {
        const ie = lock.lockDisableIrq();
        defer lock.unlockRestoreIrq(ie);
        const id = allocateId();

        th.* = .{
            .id = id,
            .tgid = id,
            .ppid = cur.tgid,
            .pgid = cur.pgid,
            .sid = cur.sid,
            .name = name,
            .state = .ready,
            .sp = @intFromPtr(sp.ptr) + sp.len,
            .stack = kstack,
            .vmm = vmm,
            .fs = fs,
            .vfork_done = if (flags.suspend_parent) &vforkw else null,
        };
        sched.enqueue(th);
    }

    // Wait for the child to exit or call execve.
    if (flags.suspend_parent) {
        vforkw.wait();
        // Clears the queue since the queue is available only on this stack frame.
        th.vfork_done = null;
    }

    return th;
}

/// Exit the current process with the given exit code.
pub fn exit(code: i32) noreturn {
    log.debug("Process exiting with code {d}", .{code});

    const cur = sched.getCurrent();
    cur.exit_status = code;

    // Release the fd table.
    cur.fs.fdtbl.deinit();

    // Release fs information.
    cur.fs.root.dentry.unref();
    cur.fs.cwd.dentry.unref();

    // Free the address space.
    cur.vmm.deinit(mem.bin);

    // Wake up the parent waiting on a vfork-clone.
    if (cur.vfork_done) |vd| {
        cur.vfork_done = null;
        vd.complete();
    }

    // Switch to the next thread. Never returns.
    sched.exitCurrent();
}

// =============================================================
// Internals

/// Allocate a new thread ID.
fn allocateId() thread.Id {
    const id = id_next;
    id_next +%= 1;

    return id;
}

/// Information needed to start executing a user thread.
const UserImage = struct {
    /// Entry point of the user thread.
    entry: usize,
    /// Initial user stack pointer.
    sp: usize,
    /// Thread pointer.
    tp: usize,
};

/// Construct a user thread image by loading the executable and preparing the user stack.
///
/// Requires the VM is set for the target thread.
fn setupUserImage(
    th: *Thread,
    filename: []const u8,
    args: []const []const u8,
    envs: []const []const u8,
) Error!UserImage {
    const allocator = mem.bin;

    // Load the executable.
    const ldr_info = try loader.load(th, filename);
    th.vmm.brk = ldr_info.brk;

    // Prepare user stack.
    const stack = try th.vmm.map(
        stack_base,
        num_stack_pages * mem.page_size,
        .rw,
    );
    @memset(stack, 0);

    // Construct stack content.
    var scon = StackCreator.init(
        stack,
        stack_base,
        allocator,
    );
    // Arguments.
    {
        try scon.appendArgv(filename);
        for (args) |arg| {
            try scon.appendArgv(arg);
        }
    }
    // Environment variables.
    {
        for (envs) |env| {
            try scon.appendEnv(env);
        }
    }
    // Auxiliary vectors.
    {
        // AT_PHDR, AT_PHENT, AT_PHNUM.
        try scon.appendAux(.new(.phdr, ldr_info.phdr_addr));
        try scon.appendAux(.new(.phent, ldr_info.phdr_entsize));
        try scon.appendAux(.new(.phnum, ldr_info.phdr_num));

        // AT_RANDOM.
        var random: [16]u8 = undefined;
        urd.rng.getRandom(&random);
        const handle = try scon.appendOpaque(&random);
        try scon.appendAux(.new(.random, @intFromEnum(handle)));

        // AT_PAGESZ.
        try scon.appendAux(.new(.pagesz, mem.page_size));
    }
    const usp = try scon.finalize();

    return .{
        .entry = ldr_info.entry,
        .sp = usp,
        .tp = ldr_info.tp,
    };
}

// =============================================================
// Thread entry point wrapper.

/// Create a wrapper struct that provides a thread entry point function.
fn ThreadFuncWrapper(comptime f: anytype, ArgType: type) type {
    return struct {
        pub fn function(argv: *const ArgType) callconv(.c) void {
            // Call function with the provided arguments.
            callThreadFunction(f, argv.*);

            // Destroy arguments.
            mem.bin.destroy(argv);

            // Exit thread.
            sched.exitCurrent();
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
const log = std.log.scoped(.task);
const Allocator = std.mem.Allocator;
const arch = @import("arch").impl;
const urd = @import("urthr");
const SpinLock = urd.SpinLock;
const mem = urd.mem;
const sched = urd.sched;
const Thread = thread.Thread;
const ThreadFs = thread.ThreadFs;
const VforkWaiter = thread.VforkWaiter;

const loader = @import("task/loader.zig");
const stk = @import("task/stack.zig");
const StackCreator = stk.StackCreator;
