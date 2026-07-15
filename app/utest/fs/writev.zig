test "syscall: writev" {
    const init = utest.getInit();
    var t = Test.init();

    const wfile = try t.createFile();
    wfile.close(init.io);
    defer t.deleteFile();

    const fd = linux.openat(
        linux.AT.FDCWD,
        Test.base_dir ++ "/" ++ Test.file_name,
        .{ .ACCMODE = .RDWR },
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const part1 = "hello-";
    const part2 = "writev";
    const iov = [_]posix.iovec_const{
        .{ .base = part1.ptr, .len = part1.len },
        .{ .base = part2.ptr, .len = part2.len },
    };
    const ret = linux.writev(@intCast(fd), &iov, iov.len);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(part1.len + part2.len, ret);

    // writev advances the file offset, so seek back before reading it back.
    const pos = linux.lseek(@intCast(fd), 0, linux.SEEK.SET);
    try testing.expectEqual(.SUCCESS, linux.errno(pos));

    // Check the file content.
    var buf: [part1.len + part2.len]u8 = undefined;
    const rret = linux.read(@intCast(fd), &buf, buf.len);
    try testing.expectEqual(.SUCCESS, linux.errno(rret));
    try testing.expectEqualSlices(u8, part1 ++ part2, &buf);
}

test "writev with an unopened fd fails with EBADF" {
    const part = "x";
    const iov = [_]posix.iovec_const{.{ .base = part.ptr, .len = part.len }};
    const ret = linux.writev(999, &iov, iov.len);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "writev with a negative fd fails with EBADF" {
    const part = "x";
    const iov = [_]posix.iovec_const{.{ .base = part.ptr, .len = part.len }};
    const ret = linux.writev(-1, &iov, iov.len);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "writev to a directory fd fails with EBADF" {
    const fd = linux.openat(
        linux.AT.FDCWD,
        "/boot",
        .{},
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const part = "x";
    const iov = [_]posix.iovec_const{.{ .base = part.ptr, .len = part.len }};
    const ret = linux.writev(@intCast(fd), &iov, iov.len);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "writev to a read-only-opened file fails with EBADF" {
    const init = utest.getInit();
    var t = Test.init();

    const wfile = try t.createFile();
    wfile.close(init.io);
    defer t.deleteFile();

    const fd = linux.openat(
        linux.AT.FDCWD,
        Test.base_dir ++ "/" ++ Test.file_name,
        .{ .ACCMODE = .RDONLY },
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const part = "x";
    const iov = [_]posix.iovec_const{.{ .base = part.ptr, .len = part.len }};
    const ret = linux.writev(@intCast(fd), &iov, iov.len);
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
