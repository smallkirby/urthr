test "with signal 0 checks for process existence without sending a signal" {
    const pid = linux.getpid();
    const ret = linux.kill(pid, @enumFromInt(0));
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

test "fails with EINVAL for an out-of-range signal number" {
    const pid = linux.getpid();
    const ret = linux.kill(pid, @enumFromInt(999));
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "fails with ESRCH for a nonexistent pid" {
    const ret = linux.kill(999_999, @enumFromInt(0));
    try testing.expectEqual(.SRCH, linux.errno(ret));
}

test "terminates another process by pid" {
    const ret = linux.fork();
    if (ret == 0) {
        _ = linux.nanosleep(&.{ .sec = 1, .nsec = 0 }, null);
        // Unreachable since the parent should kill this child.
        linux.exit_group(1);
    }
    const child_pid: linux.pid_t = @intCast(ret);
    try testing.expect(child_pid > 0);

    // Give the child time to enter sleep.
    _ = linux.nanosleep(&.{
        .sec = 0,
        .nsec = 20 * std.time.ns_per_ms,
    }, null);

    // Kill the child process.
    try testing.expectEqual(
        .SUCCESS,
        linux.errno(linux.kill(child_pid, .TERM)),
    );
    try utest.expectWaitChildSignaled(child_pid, .TERM);
}

test "can send signal#0 to its own group" {
    const ret = linux.kill(0, @enumFromInt(0));
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

var parent_pid: linux.pid_t = undefined;

test "fails with EPERM when the sender's UID does not match the target's UID" {
    parent_pid = linux.getpid();

    try utest.runChild(struct {
        pub fn lambda() !void {
            // Change UID.
            try testing.expectEqual(0, linux.setresuid(
                1000,
                1000,
                1000,
            ));

            // Try to kill the parent process whose UID is different.
            const ret = linux.kill(parent_pid, @enumFromInt(0));
            try testing.expectEqual(.PERM, linux.errno(ret));
        }
    });
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
