test "syscall: ftruncate shrinks the file" {
    const init = utest.getInit();
    var t = Test.init();

    const wfile = try t.createFile();
    try wfile.writeStreamingAll(init.io, "0123456789");
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

    const ret = linux.ftruncate(@intCast(fd), 3);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    var buf: [16]u8 = undefined;
    const n = linux.read(@intCast(fd), &buf, buf.len);
    try testing.expectEqual(.SUCCESS, linux.errno(n));
    try testing.expectEqualSlices(u8, "012", buf[0..n]);
}

test "syscall: ftruncate extends the file and zero-fills the new region" {
    const init = utest.getInit();
    var t = Test.init();

    const wfile = try t.createFile();
    try wfile.writeStreamingAll(init.io, "hello");
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

    const ret = linux.ftruncate(@intCast(fd), 10);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    var buf: [16]u8 = undefined;
    const n = linux.read(@intCast(fd), &buf, buf.len);
    try testing.expectEqual(.SUCCESS, linux.errno(n));
    try testing.expectEqualSlices(u8, "hello" ++ [_]u8{0} ** 5, buf[0..n]);
}

test "ftruncate with an unopened fd fails with EBADF" {
    const ret = linux.ftruncate(999, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "ftruncate with a negative fd fails with EBADF" {
    const ret = linux.ftruncate(-1, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "ftruncate with a negative length fails with EINVAL" {
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

    const ret = linux.ftruncate(@intCast(fd), -1);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "ftruncate on a directory fd fails with EBADF" {
    const fd = linux.openat(
        linux.AT.FDCWD,
        "/boot",
        .{},
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const ret = linux.ftruncate(@intCast(fd), 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "ftruncate on a read-only-opened file fails with EBADF" {
    const init = utest.getInit();
    var t = Test.init();

    const wfile = try t.createFile();
    try wfile.writeStreamingAll(init.io, "0123456789");
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

    const ret = linux.ftruncate(@intCast(fd), 3);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
const Test = utest.fs.Test;
