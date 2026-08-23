//! Urthr Userland Unit Test Framework.
//!
//! All tests are run in the same process.
//! So tests should clean up after themselves, and not depend on other tests.

/// Pointer to the juicy-init instance, bridged from the test runner.
export var utest_init_ptr: ?*std.process.Init = null;

/// Get juicy-init instance.
pub fn getInit() std.process.Init {
    return utest_init_ptr.?.*;
}

/// Check if the network is supported in the current environment.
pub fn skipIfNetUnsupported() !void {
    return if (options.net_supported) {} else error.SkipZigTest;
}

/// The path of this binary.
pub const myname = "/bin/utest";

// Modules.
pub const fs = @import("syscall/fs.zig");
pub const mem = @import("syscall/mem.zig");
pub const net = @import("syscall/net.zig");
pub const signal = @import("syscall/signal.zig");
pub const task = @import("syscall/task.zig");
pub const time = @import("syscall/time.zig");

// =============================================================
// Helpers
// =============================================================

pub fn runChild(T: anytype) !void {
    const ret = linux.fork();
    if (ret == 0) {
        T.lambda() catch |e| {
            linux.exit_group(@intFromError(e));
        };
        linux.exit_group(0);

        unreachable;
    }

    const child_pid: linux.pid_t = @intCast(ret);
    try testing.expect(child_pid > 0);

    var status: u32 = undefined;
    const wret = linux.wait4(child_pid, &status, 0, null);
    try testing.expectEqual(@as(usize, @intCast(child_pid)), wret);

    const exit_code = linux.W.EXITSTATUS(status);
    return if (exit_code == 0) {} else @errorFromInt(@as(u16, @intCast(exit_code)));
}

/// Run a child process and expect it to exit with the given status.
pub fn expectRunChild(expected_status: u32, T: anytype) !void {
    try expectWaitChild(forkChild(0, T), expected_status);
}

/// Wait for the child process to exit with the expected status.
pub fn expectWaitChild(child_pid: linux.pid_t, expected_status: u32) !void {
    try testing.expect(child_pid > 0);

    var status: u32 = undefined;
    const wret = linux.wait4(child_pid, &status, 0, null);
    try testing.expectEqual(@as(usize, @intCast(child_pid)), wret);
    try testing.expectEqual(expected_status, status);
}

/// Run a child process and expect it to be terminated by the given signal.
pub fn expectRunChildSignaled(sig: linux.SIG, ctx: usize, T: anytype) !void {
    try expectWaitChildSignaled(forkChild(ctx, T), sig);
}

/// Wait for the child process to be terminated by the given signal.
pub fn expectWaitChildSignaled(child_pid: linux.pid_t, sig: linux.SIG) !void {
    try testing.expect(child_pid > 0);

    var status: u32 = undefined;
    const wret = linux.wait4(child_pid, &status, 0, null);
    try testing.expectEqual(.SUCCESS, linux.errno(wret));
    try testing.expect(linux.W.IFSIGNALED(status));
    try testing.expectEqual(sig, linux.W.TERMSIG(status));
}

fn forkChild(ctx: usize, T: anytype) linux.pid_t {
    const ret = linux.fork();
    if (ret == 0) {
        T.lambda(ctx);
        unreachable;
    }
    return @intCast(ret);
}

// =============================================================
// Test References
// =============================================================

test "hello" {
    std.log.info("Hello, Urthr Unit Test Framework!", .{});
}

comptime {
    _ = @import("syscall/devfs.zig");
    _ = @import("syscall/fs.zig");
    _ = @import("syscall/mem.zig");
    _ = @import("syscall/net.zig");
    _ = @import("syscall/sched.zig");
    _ = @import("syscall/signal.zig");
    _ = @import("syscall/system.zig");
    _ = @import("syscall/task.zig");
    _ = @import("syscall/time.zig");
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;
const options = @import("options");
