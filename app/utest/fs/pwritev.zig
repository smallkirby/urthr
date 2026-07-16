test "syscall: pwritev at offset 0" {
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
    const part2 = "pwritev";
    const iov = [_]posix.iovec_const{
        .{ .base = part1.ptr, .len = part1.len },
        .{ .base = part2.ptr, .len = part2.len },
    };
    const ret = linux.pwritev(@intCast(fd), &iov, iov.len, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(part1.len + part2.len, ret);

    // Check the file content.
    var buf: [part1.len + part2.len]u8 = undefined;
    const rret = linux.read(@intCast(fd), &buf, buf.len);
    try testing.expectEqual(.SUCCESS, linux.errno(rret));
    try testing.expectEqualSlices(u8, part1 ++ part2, &buf);
}

test "with an unopened fd fails with EBADF" {
    const part = "x";
    const iov = [_]posix.iovec_const{.{ .base = part.ptr, .len = part.len }};
    const ret = linux.pwritev(999, &iov, iov.len, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "with a negative fd fails with EBADF" {
    const part = "x";
    const iov = [_]posix.iovec_const{.{ .base = part.ptr, .len = part.len }};
    const ret = linux.pwritev(-1, &iov, iov.len, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "to a read-only-opened file fails with EBADF" {
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
    const ret = linux.pwritev(@intCast(fd), &iov, iov.len, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "at a nonzero offset writes without moving the file offset" {
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
        .{ .ACCMODE = .RDWR },
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    // The file offset starts at 0 and must stay there after a pwritev call.
    const patch = "XX";
    const iov = [_]posix.iovec_const{.{ .base = patch.ptr, .len = patch.len }};
    const ret = linux.pwritev(@intCast(fd), &iov, iov.len, 4);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(patch.len, ret);

    const pos = linux.lseek(@intCast(fd), 0, linux.SEEK.CUR);
    try testing.expectEqual(@as(usize, 0), pos);

    var buf: [content.len]u8 = undefined;
    const rret = linux.read(@intCast(fd), &buf, buf.len);
    try testing.expectEqual(.SUCCESS, linux.errno(rret));
    try testing.expectEqualSlices(u8, "0123XX6789", &buf);
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
