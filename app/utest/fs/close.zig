test "close with an unopened fd fails with EBADF" {
    const ret = linux.close(999);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "close with a negative fd fails with EBADF" {
    const ret = linux.close(-1);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "closing the same fd twice fails with EBADF on the second call" {
    const ret_open = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(ret_open));
    const fd: i32 = @intCast(ret_open);

    try testing.expectEqual(.SUCCESS, linux.errno(linux.close(fd)));
    try testing.expectEqual(.BADF, linux.errno(linux.close(fd)));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
