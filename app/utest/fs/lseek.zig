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

test "lseek on a pipe fails with ESPIPE" {
    var fds: [2]i32 = undefined;
    const ret = linux.pipe2(&fds, .{});
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    const seek = linux.lseek(fds[0], 0, linux.SEEK.SET);
    try testing.expectEqual(.SPIPE, linux.errno(seek));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
