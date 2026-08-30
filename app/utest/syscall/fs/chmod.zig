// =============================================================
// fchmodat

test "syscall: fchmodat" {
    const ret = linux.fchmodat(linux.AT.FDCWD, utest.myname, 0o644);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

test "fchmodat on a non-existent file fails with ENOENT" {
    const ret = linux.fchmodat(
        linux.AT.FDCWD,
        Test.base_dir ++ "/no-such-file",
        0o644,
    );
    try testing.expectEqual(.NOENT, linux.errno(ret));
}

test "fchmodat with an unopened dirfd fails with EBADF" {
    const ret = linux.fchmodat(999, "somefile", 0o644);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "fchmodat with a negative dirfd that is not AT_FDCWD fails with EBADF" {
    const ret = linux.fchmodat(-2, "somefile", 0o644);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "fchmodat with a regular-file fd as dirfd fails with ENOTDIR" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const ret = linux.fchmodat(@intCast(fd), "somefile", 0o644);
    try testing.expectEqual(.NOTDIR, linux.errno(ret));
}

test "fchmodat resolves relative to a directory fd" {
    const init = utest.getInit();

    const dir = try std.Io.Dir.openDirAbsolute(
        init.io,
        "/bin",
        .{},
    );
    defer dir.close(init.io);

    const ret = linux.fchmodat(@intCast(dir.handle), "utest", 0o644);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

// =============================================================
// chmod

test "syscall: chmod" {
    const ret = linux.chmod(utest.myname, 0o644);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

test "chmod on a non-existent file fails with ENOENT" {
    const ret = linux.chmod(Test.base_dir ++ "/no-such-file", 0o644);
    try testing.expectEqual(.NOENT, linux.errno(ret));
}

test "chmod changes the permission bits" {
    const path = Test.base_dir ++ "chmod1";
    const fd = linux.open(
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true },
        0o666,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));
    defer _ = linux.unlink(path);

    try testing.expectEqual(.SUCCESS, linux.errno(linux.chmod(path, 0o600)));

    var statxbuf: linux.Statx align(8) = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.statx(
        linux.AT.FDCWD,
        path,
        0,
        linux.STATX.BASIC_STATS,
        &statxbuf,
    )));
    try testing.expectEqual(@as(u16, 0o600), statxbuf.mode & 0o777);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
const Test = utest.fs.Test;
