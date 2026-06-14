//! Process and thread module.

pub const loader = @import("task/loader.zig");
pub const thread = @import("task/thread.zig");
pub const Vmm = @import("task/Vmm.zig");

/// The number of pages allocated for user stack.
const num_stack_pages = 32;
/// Base address of the user stack.
const stack_base = 0x7FFF_FF00_0000;

/// Enter userland by loading the specified executable.
///
/// This function does not return on success.
pub fn enterUser(filename: []const u8, args: []const []const u8, envs: []const []const u8) !noreturn {
    const current = sched.getCurrent();
    const allocator = urd.mem.bin;

    // Initialize stdin.
    const tty = try urd.fs.open("/dev/tty", allocator);
    defer tty.unref();
    _ = try current.fs.fdtbl.set(0, tty);

    // Initialize stdout and stderr.
    const console = try urd.fs.open("/dev/console", allocator);
    defer console.unref();
    _ = try current.fs.fdtbl.set(1, console);
    _ = try current.fs.fdtbl.set(2, console);

    // Load the executable.
    const ldr_info = try loader.load(current, filename);
    current.vmm.brk = ldr_info.brk;

    // Set thread pointer.
    arch.thread.setThreadPointer(ldr_info.tp);

    // Prepare user stack.
    const stack = try current.vmm.map(
        stack_base,
        num_stack_pages * urd.mem.page_size,
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
        try scon.appendAux(.new(.pagesz, urd.mem.page_size));
    }

    const usp = try scon.finalize();

    // Enter userland.
    const kstack = current.stack.?;
    arch.thread.enterUserland(
        ldr_info.entry,
        usp,
        @intFromPtr(kstack.ptr) + kstack.len,
    );
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
    cur.vmm.deinit(urd.mem.bin);

    // Wake up the parent waiting on a vfork-clone.
    if (cur.vfork_done) |vd| {
        cur.vfork_done = null;
        vd.complete();
    }

    // Switch to the next thread. Never returns.
    sched.exitCurrent();
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.task);
const Allocator = std.mem.Allocator;
const arch = @import("arch").impl;
const urd = @import("urthr");
const sched = urd.sched;
const stk = @import("task/stack.zig");
const StackCreator = stk.StackCreator;
