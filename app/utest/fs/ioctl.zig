test "ioctl with an unopened fd fails with EBADF" {
    const ret = linux.ioctl(999, linux.T.IOCGWINSZ, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "ioctl on a regular file fails with ENOTTY" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const ret = linux.ioctl(@intCast(fd), linux.T.IOCGWINSZ, 0);
    try testing.expectEqual(.NOTTY, linux.errno(ret));
}

test "ioctl with a negative fd fails with EBADF" {
    const ret = linux.ioctl(-1, linux.T.IOCGWINSZ, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "ioctl on a directory fails with ENOTTY" {
    const fd = linux.openat(linux.AT.FDCWD, "/boot", .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const ret = linux.ioctl(@intCast(fd), linux.T.IOCGWINSZ, 0);
    try testing.expectEqual(.NOTTY, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
