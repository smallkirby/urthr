test "returns the caller's own session id for pid=0" {
    const pid = linux.getpid();
    const ret = linux.getsid(0);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(@as(usize, @intCast(pid)), ret);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
