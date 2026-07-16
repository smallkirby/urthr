test "pipe2 creates a working read/write pair" {
    var fds: [2]i32 = undefined;
    const ret = linux.pipe2(&fds, .{});
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    const content = "urthr-pipe";
    const wret = linux.write(fds[1], content, content.len);
    try testing.expectEqual(.SUCCESS, linux.errno(wret));
    try testing.expectEqual(content.len, wret);

    var buf: [content.len]u8 = undefined;
    const rret = linux.read(fds[0], &buf, buf.len);
    try testing.expectEqual(.SUCCESS, linux.errno(rret));
    try testing.expectEqual(content.len, rret);
    try testing.expectEqualSlices(u8, content, &buf);
}

test "reading from the write-end of a pipe fails with EBADF" {
    var fds: [2]i32 = undefined;
    const ret = linux.pipe2(&fds, .{});
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    var buf: [4]u8 = undefined;
    const rret = linux.read(fds[1], &buf, buf.len);
    try testing.expectEqual(.BADF, linux.errno(rret));
}

test "writing to the read-end of a pipe fails with EBADF" {
    var fds: [2]i32 = undefined;
    const ret = linux.pipe2(&fds, .{});
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    const content = "x";
    const wret = linux.write(fds[0], content, content.len);
    try testing.expectEqual(.BADF, linux.errno(wret));
}

test "reading from a pipe after the write-end is closed returns EOF" {
    var fds: [2]i32 = undefined;
    const ret = linux.pipe2(&fds, .{});
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.close(fds[0]);

    try testing.expectEqual(.SUCCESS, linux.errno(linux.close(fds[1])));

    var buf: [4]u8 = undefined;
    const rret = linux.read(fds[0], &buf, buf.len);
    try testing.expectEqual(.SUCCESS, linux.errno(rret));
    try testing.expectEqual(0, rret);
}

test "writing to a pipe after the read-end is closed fails with EPIPE" {
    // Ignore EPIPE signal.
    const sa: linux.Sigaction = .{
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    try testing.expectEqual(.SUCCESS, linux.errno(linux.sigaction(.PIPE, &sa, null)));

    var fds: [2]i32 = undefined;
    const ret = linux.pipe2(&fds, .{});
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.close(fds[1]);

    try testing.expectEqual(.SUCCESS, linux.errno(linux.close(fds[0])));

    const content = "x";
    const wret = linux.write(fds[1], content, content.len);
    try testing.expectEqual(.PIPE, linux.errno(wret));
}

test "pipe2 with O_CLOEXEC sets the close-on-exec flag on both ends" {
    var fds: [2]i32 = undefined;
    const ret = linux.pipe2(&fds, .{ .CLOEXEC = true });
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    const FD_CLOEXEC = 1;
    for (fds) |fd| {
        const got = linux.fcntl(fd, linux.F.GETFD, 0);
        try testing.expectEqual(.SUCCESS, linux.errno(got));
        try testing.expectEqual(FD_CLOEXEC, got);
    }
}

test "pipe2 with an invalid flag bit fails with EINVAL" {
    var fds: [2]i32 = undefined;
    const O_CREAT = 0o100;
    const ret = linux.syscall2(.pipe2, @intFromPtr(&fds), O_CREAT);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
