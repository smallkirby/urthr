test "getpgid returns the caller's own process group for pid=0" {
    const pid = linux.getpid();
    const ret = linux.getpgid(0);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(@as(usize, @intCast(pid)), ret);
}

test "getpgid for the caller's own pid succeeds" {
    const pid = linux.getpid();
    const ret = linux.getpgid(pid);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
