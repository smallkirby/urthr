//! Process and thread module.
//!
//! #### Transition of thread state
//!
//! - running -> blocked: Thread blocks on an event and yields the CPU.
//! - blocked -> running: Thread is woken up by an event and added to the ready queue.
//! - running -> moribund: Thread who is a last member of a group exits and waits for being switched out.
//! - running -> dead: Thread who is not a last member of a group exits and waits for being switched out.
//! - moribund -> zombie: Thread is switched out and becomes a zombie.
//! - zombie -> (deinit): Thread is reaped by the parent and freed.

pub const signal = @import("task/signal.zig");
pub const thread = @import("task/thread.zig");
pub const Vmm = @import("task/Vmm.zig");
pub const ThreadGroup = @import("task/ThreadGroup.zig");
pub const Credential = @import("task/Credential.zig");

pub const Error = error{
    /// Invalid argument provided.
    InvalidArgument,
    /// Memory allocation failed.
    OutOfMemory,
    /// There's no child process matching the given PID.
    NoChild,
} || loader.Error;

/// The number of pages allocated for user stack.
const num_stack_pages = 32;
/// Base address of the user stack.
const stack_base = 0x7FFF_FF00_0000;

/// Spin lock for scheduler and thread management.
var lock: SpinLock = .{};
/// Thread ID assigned to the next created thread.
var id_next: thread.Id = 1;

/// Dead threads waiting to be reaped by their parent.
var zombie_list: ThreadList = .{};
/// Protects the zombie list.
var zombie_lock: SpinLock = .{};

/// Initialize the task subsystem.
pub fn init() void {
    // Set #PF handler.
    arch.setPageFaultHandler(handlePageFault);
}

/// Handle a page fault.
///
/// Backs the faulting page on demand, or delivers a signal if the access cannot be satisfied.
fn handlePageFault(far: usize, access: common.mem.AccessType) bool {
    const th = sched.getCurrent();

    th.vmm.faultIn(far, access) catch |err| {
        // Failed to handle the fault. Immediately terminate the current thread.
        log.warn("Unhandled #PF: TGID={d} ID={d} FAR=0x{X} ACCESS={} ERR={}", .{ th.group.getTgid(), th.id, far, access, err });
        signal.pushSync(.segv);
    };

    return true;
}

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

    // Create a new thread group for the new kernel thread.
    const id = allocateId();
    const group = try ThreadGroup.new(mem.bin, th, id, id, id);
    errdefer group.deref(mem.bin);
    const handlers = try signal.Handlers.new(mem.bin);
    errdefer handlers.deinit(mem.bin);

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
    th.* = .{
        .id = id,
        .ppid = cur.group.getTgid(),
        .name = name,
        .state = .running,
        .sp = @intFromPtr(sp.ptr) + sp.len,
        .stack = stack,
        .vmm = vmm,
        .fs = fs,
        .sigstate = .{ .handlers = handlers },
        .group = group,
        .parent = cur.group.ref(),
    };
    group.addMember(th);

    // Register as a child of the current thread group.
    {
        const ie = zombie_lock.lockDisableIrq();
        defer zombie_lock.unlockRestoreIrq(ie);
        cur.group.children.append(th);
    }

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
    arch.mmu.switchAddressSpace(new_vm.as, mem.page);
    // Rollback VM on failure.
    errdefer {
        current.vmm = old_vm;
        arch.mmu.switchAddressSpace(old_vm.as, mem.page);
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
    const tty = try urd.fs.open("/dev/tty", .read_only, allocator);
    defer tty.unref();
    _ = try current.fs.fdtbl.set(0, tty);

    // Initialize stdout and stderr.
    const console = try urd.fs.open("/dev/console", .write_only, allocator);
    defer console.unref();
    _ = try current.fs.fdtbl.set(1, console);
    _ = try current.fs.fdtbl.set(2, console);

    // Build the full argv.
    const argv = try allocator.alloc([]const u8, args.len + 1);
    errdefer allocator.free(argv);
    argv[0] = filename;
    @memcpy(argv[1..], args);

    // Setup user image.
    const uimg = try setupUserImage(
        current,
        filename,
        argv,
        envs,
    );
    allocator.free(argv);

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
    /// Shares the same thread group as the caller.
    thread: bool,
    /// Shares the signal handler table with the caller.
    sighand: bool,
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
    const pctx = sched.getCurrentCtx();
    const usp = if (stack != 0)
        stack
    else
        arch.thread.userStackPointerOf(pctx);
    const sp = arch.thread.initStackFork(
        kstack,
        pctx,
        usp,
    );

    const id = blk: {
        const ie = lock.lockDisableIrq();
        defer lock.unlockRestoreIrq(ie);
        break :blk allocateId();
    };

    // Share or copy VM.
    const vmm = if (flags.vm)
        cur.vmm.ref()
    else
        cur.vmm.clone(mem.bin) catch return Error.OutOfMemory;
    errdefer vmm.deinit(mem.bin);

    // Share or copy the thread group.
    const group = if (flags.thread)
        cur.group.ref()
    else blk: {
        const g = try ThreadGroup.new(
            mem.bin,
            th,
            id,
            cur.group.getPgid(),
            cur.group.getSid(),
        );
        g.setCredential(cur.group.getCredential());
        break :blk g;
    };
    errdefer group.deref(mem.bin);

    // Share or copy the signal handler table.
    const handlers = if (flags.sighand)
        cur.sigstate.handlers.ref()
    else
        cur.sigstate.handlers.clone(mem.bin) catch return Error.OutOfMemory;
    errdefer handlers.deinit(mem.bin);

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

        th.* = .{
            .id = id,
            .ppid = if (flags.thread) cur.ppid else cur.group.getTgid(),
            .name = name,
            .state = .running,
            .sp = @intFromPtr(sp.ptr) + sp.len,
            .stack = kstack,
            .vmm = vmm,
            .fs = fs,
            .sigstate = .{ .handlers = handlers, .blocked = cur.sigstate.blocked },
            .group = group,
            .vfork_done = if (flags.suspend_parent) &vforkw else null,
            .parent = if (flags.thread) null else cur.group.ref(),
        };
        group.addMember(th);
        if (!flags.thread) {
            const zombie_ie = zombie_lock.lockDisableIrq();
            defer zombie_lock.unlockRestoreIrq(zombie_ie);
            cur.group.children.append(th);
        }
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

/// Exit the current process with the given exit code or signal.
pub fn exit(status: thread.ExitStatus) noreturn {
    const cur = sched.getCurrent();
    cur.exit_status = status;

    // Check if the current thread is init.
    if (cur.group.getTgid() == 1 and cur.id == 1) {
        @branchHint(.cold);

        if (urd.allow_init_exit) {
            log.info("Init process exited with {}", .{status});
            urd.eol(switch (status) {
                .code => |c| @intCast(c),
                .signal => 1,
            });
        } else {
            @panic("Init process exited.");
        }
    }

    // Release thread resources.
    releaseThread(cur);

    // Wake up the parent waiting on a vfork-clone.
    if (cur.vfork_done) |vd| {
        cur.vfork_done = null;
        vd.complete();
    }

    // Leave the thread group.
    const is_last = cur.group.leave(cur);
    // Switch to the next thread.
    sched.exitCurrent(if (is_last) .moribund else .dead);

    unreachable;
}

/// Called on a thread has been switched out.
pub fn onSwitchedOut(prev: *Thread) void {
    switch (prev.state) {
        // When the thread was a last member of the group.
        .moribund => becomeZombie(prev),
        // When the thread was not the last member of the group.
        // Group leader is kept alive until the last member exits.
        .dead => if (prev.group.getLeader() != prev) shutdownThread(prev),
        else => {},
    }
}

/// Turn the thread into a zombie thread.
fn becomeZombie(th: *Thread) void {
    const ie = zombie_lock.lockDisableIrq();
    defer zombie_lock.unlockRestoreIrq(ie);

    const leader = th.group.getLeader();
    if (leader != th) {
        // The original leader exited earlier and was kept alive for this.
        // Transfer its parent-group reference and ID to the new leader.
        th.parent = leader.parent;
        leader.parent = null;
        th.ppid = leader.ppid;
        if (th.parent) |p| p.children.remove(leader);
        // Then clean up the original leader.
        shutdownThread(leader);
    } else if (th.parent) |p| {
        p.children.remove(th);
    }

    // Append the thread to the zombie list.
    th.state = .zombie;
    zombie_list.append(th);

    // Notify the parent group that a child has exited.
    if (th.parent) |p| {
        p.child_exit_cv.signal();
    }
}

/// Release the resources of a thread.
fn releaseThread(th: *thread.Thread) void {
    // Disarm any interval timer.
    urd.time.cancelItimer(th);

    // Release the fd table.
    th.fs.fdtbl.deinit();

    // Release fs information.
    th.fs.root.dentry.unref();
    th.fs.cwd.dentry.unref();

    // Free the address space.
    th.vmm.deinit(mem.bin);

    // Release the signal handler table.
    th.sigstate.handlers.deinit(mem.bin);
}

/// Colempletely shutdown the given thread, freeing all its resources.
///
/// After this function, the thread struct and related resources are no longer accessible.
pub fn shutdownThread(th: *thread.Thread) void {
    if (th.stack) |kstack| mem.page.freeBytesV(kstack);
    if (th.parent) |p| p.deref(mem.bin);
    mem.bin.free(th.name);
    th.group.deref(mem.bin);
    mem.bin.destroy(th);
}

/// Terminate every thread in the current thread group with the given exit code or signal.
///
/// Other threads in the group marked dying will cooperatively exit when they're scheduled.
pub fn exitGroup(status: thread.ExitStatus) noreturn {
    const cur = sched.getCurrent();
    cur.group.markDying(status);
    exit(status);
}

const WaitResult = struct {
    /// PID of the reaped child.
    pid: u32,
    /// Raw exit status.
    exit_status: thread.ExitStatus,
};

/// Wait for a child thread to exit and reap it.
///
/// Returns null when nowait is true and no matching child has exited yet.
/// Returns an error when there's no child matching the given PID.
pub fn waitChild(pid: i32, nowait: bool) error{NoChild}!?WaitResult {
    const cur = sched.getCurrent();

    const ie = zombie_lock.lockDisableIrq();
    defer zombie_lock.unlockRestoreIrq(ie);

    while (true) {
        // Check zombie list.
        var it = zombie_list.iter();
        while (it.next()) |th| {
            if (!matchesChild(cur, pid, th)) continue;

            rtt.expectEqual(.zombie, th.state);

            zombie_list.remove(th);

            const result: WaitResult = .{
                .pid = th.group.getTgid(),
                .exit_status = th.exit_status,
            };
            shutdownThread(th);

            return result;
        }

        // Check for alive matching children.
        var child_it = cur.group.children.iter();
        while (child_it.next()) |th| {
            if (matchesChild(cur, pid, th)) break;
        } else {
            return error.NoChild;
        }

        if (!nowait) {
            cur.group.child_exit_cv.wait(&zombie_lock);
        } else {
            return null;
        }
    }
}

/// Check if the given child thread matches the PID in POSIX-way.
fn matchesChild(parent: *const Thread, pid: i32, child: *const Thread) bool {
    if (child.ppid != parent.group.getTgid()) return false;
    if (pid == -1) return true; // any child.
    if (pid > 0) return child.group.getTgid() == @as(u32, @bitCast(pid)); // any child in process group.
    if (pid == 0) return child.group.getPgid() == parent.group.getPgid(); // specific child with TGID == PID.
    return child.group.getPgid() == @as(u32, @bitCast(-pid)); // any child with PGID == -PID.
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
    argv: []const []const u8,
    envs: []const []const u8,
) Error!UserImage {
    const allocator = mem.bin;
    var exec_filename = filename;
    var exec_argv = argv;

    // Resolve a shebang line first.
    var rewritten_argv: ?[][]const u8 = null;
    const shebang = try loader.parseShebang(filename, allocator);
    defer if (shebang) |sb| {
        allocator.free(sb.interp);
        if (sb.arg) |a| allocator.free(a);
    };
    defer if (rewritten_argv) |ra| {
        allocator.free(ra);
    };

    // Rewrite argv if a shebang is found.
    if (shebang) |sb| {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(allocator);

        // argv[0]: interpreter path
        try list.append(allocator, sb.interp);
        // argv[1]: optional argument to the interpreter
        if (sb.arg) |a| {
            try list.append(allocator, a);
        }
        // argv[2]: original executable path
        try list.append(allocator, filename);
        // argv[3..]: original arguments
        if (argv.len > 1) {
            try list.appendSlice(allocator, argv[1..]);
        }

        exec_filename = sb.interp;
        rewritten_argv = try list.toOwnedSlice(allocator);
        exec_argv = rewritten_argv.?;
    }

    // Load the executable.
    const ldr_info = try loader.load(th, exec_filename);
    th.vmm.brk = ldr_info.brk;

    // Apply set-user-ID and set-group-ID bits.
    if (ldr_info.setuid != null or ldr_info.setgid != null) {
        var cred = th.group.getCredential();
        if (ldr_info.setuid) |uid| {
            cred.euid = uid;
            cred.suid = uid;
        }
        if (ldr_info.setgid) |gid| {
            cred.egid = gid;
            cred.sgid = gid;
        }
        th.group.setCredential(cred);
    }

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
        for (exec_argv) |arg| {
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
            sched.exitCurrent(.dead);
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
const common = @import("common");
const rtt = common.rtt;
const arch = @import("arch").impl;
const urd = @import("urthr");
const SpinLock = urd.sync.SpinLock;
const mem = urd.mem;
const sched = urd.sched;
const Thread = thread.Thread;
const ThreadFs = thread.ThreadFs;
const ThreadList = thread.ThreadList;
const ChildrenList = thread.ChildrenList;
const VforkWaiter = thread.VforkWaiter;

const loader = @import("task/loader.zig");
const stk = @import("task/stack.zig");
const StackCreator = stk.StackCreator;
