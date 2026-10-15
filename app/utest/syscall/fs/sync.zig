test "fsync on a written regular file succeeds" {
    const fd = try createFile(path);
    defer cleanup(fd);

    try testing.expectEqual(@as(usize, 4), linux.write(fd, "abcd", 4));
    try testing.expectEqual(.SUCCESS, linux.errno(linux.fsync(fd)));
}

test "fdatasync on a written regular file succeeds" {
    const fd = try createFile(path);
    defer cleanup(fd);

    try testing.expectEqual(@as(usize, 4), linux.write(fd, "abcd", 4));
    try testing.expectEqual(.SUCCESS, linux.errno(linux.fdatasync(fd)));
}

test "fsync does not change the file content" {
    const fd = try createFile(path);
    defer cleanup(fd);

    try testing.expectEqual(@as(usize, 4), linux.write(fd, "abcd", 4));
    try testing.expectEqual(.SUCCESS, linux.errno(linux.fsync(fd)));

    var buf: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), linux.lseek(fd, 0, linux.SEEK.SET));
    try testing.expectEqual(@as(usize, 4), linux.read(fd, &buf, buf.len));
    try testing.expectEqualStrings("abcd", &buf);
}

test "fsync with an unopened fd fails with EBADF" {
    try testing.expectEqual(.BADF, linux.errno(linux.fsync(999)));
    try testing.expectEqual(.BADF, linux.errno(linux.fdatasync(999)));
}

test "fsync on a pipe fails with EINVAL" {
    var fds: [2]i32 = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.pipe(&fds)));
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    try testing.expectEqual(.INVAL, linux.errno(linux.fsync(fds[1])));
}

test "syncfs on a regular file succeeds" {
    const fd = try createFile(path);
    defer cleanup(fd);

    try testing.expectEqual(@as(usize, 4), linux.write(fd, "abcd", 4));
    try testing.expectEqual(.SUCCESS, linux.errno(linux.syncfs(fd)));
}

test "syncfs with an unopened fd fails with EBADF" {
    try testing.expectEqual(.BADF, linux.errno(linux.syncfs(999)));
}

test "sync succeeds" {
    const fd = try createFile(path);
    defer cleanup(fd);

    try testing.expectEqual(@as(usize, 4), linux.write(fd, "abcd", 4));
    linux.sync();
}

// =============================================================
// Helpers
// =============================================================

const path = "/synct1";

fn createFile(p: [:0]const u8) !i32 {
    const ret = linux.open(p, .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    return @intCast(ret);
}

fn cleanup(fd: i32) void {
    _ = linux.close(fd);
    _ = linux.unlink(path);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
