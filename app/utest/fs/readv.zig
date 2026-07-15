test "syscall: readv" {
    const init = utest.getInit();

    const file = try std.Io.Dir.openFileAbsolute(
        init.io,
        utest.myname,
        .{},
    );
    defer file.close(init.io);

    var buf1: [2]u8 = undefined;
    var buf2: [2]u8 = undefined;
    const iov = [_]posix.iovec{
        .{ .base = &buf1, .len = buf1.len },
        .{ .base = &buf2, .len = buf2.len },
    };
    const ret = linux.readv(@intCast(file.handle), &iov, iov.len);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(buf1.len + buf2.len, ret);
    try testing.expectEqualSlices(u8, std.elf.MAGIC[0..2], &buf1);
    try testing.expectEqualSlices(u8, std.elf.MAGIC[2..4], &buf2);
}

test "readv with an unopened fd fails with EBADF" {
    var buf: [4]u8 = undefined;
    const iov = [_]posix.iovec{.{ .base = &buf, .len = buf.len }};
    const ret = linux.readv(999, &iov, iov.len);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "readv with a negative fd fails with EBADF" {
    var buf: [4]u8 = undefined;
    const iov = [_]posix.iovec{.{ .base = &buf, .len = buf.len }};
    const ret = linux.readv(-1, &iov, iov.len);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "readv from a directory fd fails with EISDIR" {
    const fd = linux.openat(linux.AT.FDCWD, "/boot", .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    var buf: [4]u8 = undefined;
    const iov = [_]posix.iovec{.{ .base = &buf, .len = buf.len }};
    const ret = linux.readv(@intCast(fd), &iov, iov.len);
    try testing.expectEqual(.ISDIR, linux.errno(ret));
}

test "readv from a write-only-opened file fails with EBADF" {
    const init = utest.getInit();
    var t = Test.init();

    const wfile = try t.createFile();
    wfile.close(init.io);
    defer t.deleteFile();

    const fd = linux.openat(
        linux.AT.FDCWD,
        Test.base_dir ++ "/" ++ Test.file_name,
        .{ .ACCMODE = .WRONLY },
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    var buf: [4]u8 = undefined;
    const iov = [_]posix.iovec{.{ .base = &buf, .len = buf.len }};
    const ret = linux.readv(@intCast(fd), &iov, iov.len);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const posix = std.posix;
const utest = @import("../utest.zig");
const Test = utest.fs.Test;
