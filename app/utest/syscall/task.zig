/// Spawns a thread sibling sharing the caller's address space, signal handlers and thread group.
///
/// Returns the new thread's TID.
pub fn spawnThread(func: *const fn (usize) callconv(.c) u8, arg: usize) !linux.pid_t {
    const stack_size = 64 * 1024;
    const stack = try std.posix.mmap(
        null,
        stack_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    const sp = @intFromPtr(stack.ptr) + stack.len;
    const flags: u32 = linux.CLONE.VM | linux.CLONE.THREAD | linux.CLONE.SIGHAND;
    const ret = linux.clone(func, sp, flags, arg, null, 0, null);
    if (linux.errno(ret) != .SUCCESS) return error.CloneFailed;
    return @bitCast(@as(u32, @truncate(ret)));
}

comptime {
    _ = @import("task/clone.zig");
    _ = @import("task/exit.zig");
    _ = @import("task/fork.zig");
    _ = @import("task/getpid.zig");
    _ = @import("task/gettid.zig");
    _ = @import("task/getuid.zig");
    _ = @import("task/geteuid.zig");
    _ = @import("task/getgid.zig");
    _ = @import("task/getegid.zig");
    _ = @import("task/getresuid.zig");
    _ = @import("task/getresgid.zig");
    _ = @import("task/getpgid.zig");
    _ = @import("task/getsid.zig");
    _ = @import("task/prlimit64.zig");
    _ = @import("task/reboot.zig");
    _ = @import("task/setpgid.zig");
    _ = @import("task/setsid.zig");
    _ = @import("task/setuid.zig");
    _ = @import("task/setgid.zig");
    _ = @import("task/setreuid.zig");
    _ = @import("task/setregid.zig");
    _ = @import("task/setresuid.zig");
    _ = @import("task/setresgid.zig");
    _ = @import("task/setgroups.zig");
    _ = @import("task/thread_group.zig");
    _ = @import("task/wait4.zig");
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const linux = std.os.linux;
