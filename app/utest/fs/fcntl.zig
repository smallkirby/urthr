test "fcntl F_GETFD with an unopened fd fails with EBADF" {
    const ret = linux.fcntl(999, linux.F.GETFD, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "fcntl F_SETFD with an unopened fd fails with EBADF" {
    const ret = linux.fcntl(999, linux.F.SETFD, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "fcntl F_GETFL with an unopened fd fails with EBADF" {
    const ret = linux.fcntl(999, linux.F.GETFL, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "fcntl F_SETFL with an unopened fd fails with EBADF" {
    const ret = linux.fcntl(999, linux.F.SETFL, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "fcntl F_DUPFD with an unopened fd fails with EBADF" {
    const ret = linux.fcntl(999, linux.F.DUPFD, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "fcntl F_DUPFD duplicates the fd to the lowest available >= arg" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const min_fd = 50;
    const dup = linux.fcntl(@intCast(fd), linux.F.DUPFD, min_fd);
    try testing.expectEqual(.SUCCESS, linux.errno(dup));
    defer _ = linux.close(@intCast(dup));

    try testing.expect(dup >= min_fd);
    try testing.expect(dup != fd);
}

test "fcntl F_GETFD/F_SETFD roundtrips the close-on-exec flag" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    // FD_CLOEXEC is not set by default.
    const got = linux.fcntl(@intCast(fd), linux.F.GETFD, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(got));
    try testing.expectEqual(0, got);

    const FD_CLOEXEC = 1;
    const set = linux.fcntl(@intCast(fd), linux.F.SETFD, FD_CLOEXEC);
    try testing.expectEqual(.SUCCESS, linux.errno(set));

    const got2 = linux.fcntl(@intCast(fd), linux.F.GETFD, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(got2));
    try testing.expectEqual(FD_CLOEXEC, got2);
}

test "fcntl F_GETFL/F_SETFL roundtrips status flags" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const got = linux.fcntl(@intCast(fd), linux.F.GETFL, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(got));

    const O_NONBLOCK = 0o4000;
    const set = linux.fcntl(@intCast(fd), linux.F.SETFL, got | O_NONBLOCK);
    try testing.expectEqual(.SUCCESS, linux.errno(set));

    const got2 = linux.fcntl(@intCast(fd), linux.F.GETFL, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(got2));
    try testing.expect(got2 & O_NONBLOCK != 0);
}

test "fcntl with an unknown command fails with EINVAL" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const ret = linux.fcntl(@intCast(fd), 0x7FFF, 0);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "fcntl F_DUPFD with an out-of-range arg fails with EINVAL" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const ret = linux.fcntl(@intCast(fd), linux.F.DUPFD, std.math.maxInt(usize));
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
