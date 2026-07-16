test "syscall: preadv at offset 0" {
    const init = utest.getInit();

    const file = try std.Io.Dir.openFileAbsolute(
        init.io,
        utest.myname,
        .{},
    );
    defer file.close(init.io);

    var buf: [4]u8 = undefined;
    const iov = [_]posix.iovec{.{ .base = &buf, .len = buf.len }};
    const ret = linux.preadv(@intCast(file.handle), &iov, iov.len, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqualSlices(u8, std.elf.MAGIC, &buf);
}

test "with an unopened fd fails with EBADF" {
    var buf: [4]u8 = undefined;
    const iov = [_]posix.iovec{.{ .base = &buf, .len = buf.len }};
    const ret = linux.preadv(999, &iov, iov.len, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "with a negative fd fails with EBADF" {
    var buf: [4]u8 = undefined;
    const iov = [_]posix.iovec{.{ .base = &buf, .len = buf.len }};
    const ret = linux.preadv(-1, &iov, iov.len, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "from a write-only-opened file fails with EBADF" {
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
    const ret = linux.preadv(@intCast(fd), &iov, iov.len, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "at a nonzero offset reads without moving the file offset" {
    const init = utest.getInit();
    var t = Test.init();

    const content = "0123456789";
    const wfile = try t.createFile();
    try wfile.writeStreamingAll(init.io, content);
    wfile.close(init.io);
    defer t.deleteFile();

    const fd = linux.openat(
        linux.AT.FDCWD,
        Test.base_dir ++ "/" ++ Test.file_name,
        .{},
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    var buf: [4]u8 = undefined;
    const iov = [_]posix.iovec{.{ .base = &buf, .len = buf.len }};
    const ret = linux.preadv(@intCast(fd), &iov, iov.len, 4);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(buf.len, ret);
    try testing.expectEqualSlices(u8, "4567", &buf);

    // The file offset starts at 0 and must stay there after a preadv call.
    const pos = linux.lseek(@intCast(fd), 0, linux.SEEK.CUR);
    try testing.expectEqual(@as(usize, 0), pos);
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
