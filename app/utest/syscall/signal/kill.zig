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

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
