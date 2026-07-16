test "fails with EINVAL for a negative pgid" {
    const ret = linux.syscall2(.setpgid, 0, @bitCast(@as(isize, -1)));
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "on a session leader fails with EPERM" {
    const ret = linux.setpgid(0, 0);
    try testing.expectEqual(.PERM, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
