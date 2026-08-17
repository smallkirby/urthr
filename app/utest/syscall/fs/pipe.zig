test "pipe creates a working read/write pair" {
    if (comptime !builtin.cpu.arch.isX86()) return error.SkipZigTest;

    var fds: [2]i32 = undefined;
    const ret = linux.pipe(&fds);
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

test "a single write wakes all readers blocked on the same pipe" {
    var pfds: [2]i32 = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&pfds, .{})));
    defer _ = linux.close(pfds[0]);
    defer _ = linux.close(pfds[1]);

    const S = struct {
        fn readOne(fd: usize) callconv(.c) u8 {
            var buf: [1]u8 = undefined;
            _ = linux.read(@intCast(fd), &buf, 1);
            linux.exit(0);
        }
    };

    // Spawn a thread that also blocks reading from the same pipe read-end.
    _ = try utest.task.spawnThread(S.readOne, @intCast(pfds[0]));

    // Fork a process that performs a single write of 2 bytes.
    const ret = linux.fork();
    if (ret == 0) {
        const ts: linux.timespec = .{ .sec = 0, .nsec = 50_000_000 };
        _ = utest.time.clockNanoSleep(utest.time.CLOCK_MONOTONIC, 0, &ts, null);
        const data = [_]u8{ 1, 2 };
        _ = linux.write(pfds[1], &data, data.len);
        linux.exit(0);
    }
    const child_pid: linux.pid_t = @intCast(ret);
    try testing.expect(child_pid > 0);

    // Leader also blocks reading from the same pipe.
    var buf: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), linux.read(pfds[0], &buf, 1));

    // Check if the child process got waken up and exited.
    var status: u32 = undefined;
    _ = linux.wait4(child_pid, &status, 0, null);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
