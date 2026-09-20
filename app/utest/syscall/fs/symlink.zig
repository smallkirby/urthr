// =============================================================
// symlink / symlinkat

test "symlinkat a new name on the FAT32 root fails with EPERM" {
    const ret = linux.symlinkat(
        "target1",
        linux.AT.FDCWD,
        Test.base_dir ++ "symlnk1",
    );
    try testing.expectEqual(.PERM, linux.errno(ret));
}

test "symlink (cwd-relative) also fails with EPERM on the FAT32 root" {
    const ret = linux.symlink("target1", Test.base_dir ++ "symlnk2");
    try testing.expectEqual(.PERM, linux.errno(ret));
}

test "symlinkat over an existing name fails with EEXIST" {
    const init = utest.getInit();
    var t = Test.init();

    const wfile = try t.createFile();
    wfile.close(init.io);
    defer t.deleteFile();

    const ret = linux.symlinkat(
        "target1",
        linux.AT.FDCWD,
        Test.base_dir ++ Test.file_name,
    );
    try testing.expectEqual(.EXIST, linux.errno(ret));
}

test "symlinkat to a non-existent parent directory fails with ENOENT" {
    const ret = linux.symlinkat(
        "target1",
        linux.AT.FDCWD,
        Test.base_dir ++ "nosuchdir/symlnk3",
    );
    try testing.expectEqual(.NOENT, linux.errno(ret));
}

test "symlinkat with an unopened dirfd fails with EBADF" {
    const ret = linux.symlinkat("target1", 999, "symlnk4");
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "symlinkat with a regular-file fd as dirfd fails with ENOTDIR" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const ret = linux.symlinkat("target1", @intCast(fd), "symlnk5");
    try testing.expectEqual(.NOTDIR, linux.errno(ret));
}

// =============================================================
// readlink / readlinkat

test "readlinkat on a regular file fails with EINVAL" {
    const init = utest.getInit();
    var t = Test.init();

    const wfile = try t.createFile();
    wfile.close(init.io);
    defer t.deleteFile();

    var buf: [64]u8 = undefined;
    const ret = linux.readlinkat(
        linux.AT.FDCWD,
        Test.base_dir ++ Test.file_name,
        &buf,
        buf.len,
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "readlink fails with EINVAL on a regular file" {
    const init = utest.getInit();
    var t = Test.init();

    const wfile = try t.createFile();
    wfile.close(init.io);
    defer t.deleteFile();

    var buf: [64]u8 = undefined;
    const ret = linux.readlink(
        Test.base_dir ++ Test.file_name,
        &buf,
        buf.len,
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "readlinkat on a non-existent path fails with ENOENT" {
    var buf: [64]u8 = undefined;
    const ret = linux.readlinkat(
        linux.AT.FDCWD,
        Test.base_dir ++ "no-such-symlink",
        &buf,
        buf.len,
    );
    try testing.expectEqual(.NOENT, linux.errno(ret));
}

test "readlinkat with an unopened dirfd fails with EBADF" {
    var buf: [64]u8 = undefined;
    const ret = linux.readlinkat(
        999,
        "symlnk",
        &buf,
        buf.len,
    );
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "readlinkat with a regular-file fd as dirfd fails with ENOTDIR" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    var buf: [64]u8 = undefined;
    const ret = linux.readlinkat(
        @intCast(fd),
        "symlnk",
        &buf,
        buf.len,
    );
    try testing.expectEqual(.NOTDIR, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
const Test = utest.fs.Test;
