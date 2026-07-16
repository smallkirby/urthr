test "on a regular file reports POLLIN and POLLOUT" {
    const init = utest.getInit();

    const file = try std.Io.Dir.openFileAbsolute(
        init.io,
        utest.myname,
        .{},
    );
    defer file.close(init.io);

    var fds = [_]linux.pollfd{.{
        .fd = @intCast(file.handle),
        .events = linux.POLL.IN | linux.POLL.OUT,
        .revents = 0,
    }};
    var timeout: linux.timespec = .{ .sec = 0, .nsec = 0 };
    const ret = linux.ppoll(&fds, fds.len, &timeout, null);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(@as(usize, 1), ret);
    try testing.expect(fds[0].revents & linux.POLL.IN != 0);
    try testing.expect(fds[0].revents & linux.POLL.OUT != 0);
}

test "with an unopened fd reports POLLNVAL" {
    var fds = [_]linux.pollfd{.{
        .fd = 999,
        .events = linux.POLL.IN,
        .revents = 0,
    }};
    var timeout: linux.timespec = .{ .sec = 0, .nsec = 0 };
    const ret = linux.ppoll(&fds, fds.len, &timeout, null);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(@as(usize, 1), ret);
    try testing.expect(fds[0].revents & linux.POLL.NVAL != 0);
}

test "ignores negative fds" {
    var fds = [_]linux.pollfd{
        .{ .fd = -1, .events = linux.POLL.IN, .revents = 0 },
    };
    var timeout: linux.timespec = .{ .sec = 0, .nsec = 0 };
    const ret = linux.ppoll(&fds, fds.len, &timeout, null);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(@as(usize, 0), ret);
    try testing.expectEqual(@as(i16, 0), fds[0].revents);
}

test "with too many fds fails with EINVAL" {
    var fds: [9]linux.pollfd = undefined;
    for (&fds) |*pfd| pfd.* = .{
        .fd = -1,
        .events = 0,
        .revents = 0,
    };

    var timeout: linux.timespec = .{ .sec = 0, .nsec = 0 };
    const ret = linux.ppoll(&fds, fds.len, &timeout, null);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
