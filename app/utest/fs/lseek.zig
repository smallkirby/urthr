test "lseek with an unopened fd fails with EBADF" {
    const ret = linux.lseek(
        999,
        0,
        linux.SEEK.SET,
    );
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "lseek with an invalid whence fails with EINVAL" {
    const init = utest.getInit();

    const file = try std.Io.Dir.openFileAbsolute(
        init.io,
        utest.myname,
        .{},
    );
    defer file.close(init.io);

    const ret = linux.lseek(@intCast(file.handle), 0, 99);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "lseek to a negative offset fails with EINVAL" {
    const init = utest.getInit();

    const file = try std.Io.Dir.openFileAbsolute(
        init.io,
        utest.myname,
        .{},
    );
    defer file.close(init.io);

    const ret = linux.lseek(@intCast(file.handle), -1, linux.SEEK.SET);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
