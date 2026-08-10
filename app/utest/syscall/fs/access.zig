test "syscall: access" {
    const ret = linux.access(utest.myname, linux.F_OK);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

test "access checks R_OK/W_OK/X_OK" {
    const ret = linux.access(utest.myname, linux.R_OK | linux.W_OK | linux.X_OK);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

test "access on a non-existent file fails with ENOENT" {
    const ret = linux.access(Test.base_dir ++ "/no-such-file", linux.F_OK);
    try testing.expectEqual(.NOENT, linux.errno(ret));
}

test "access with an invalid mode bit fails with EINVAL" {
    const ret = linux.access(utest.myname, 0x8);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "syscall: faccessat" {
    const ret = linux.faccessat(linux.AT.FDCWD, utest.myname, linux.F_OK, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

test "faccessat with an unopened dirfd fails with EBADF" {
    const ret = linux.faccessat(999, "somefile", linux.F_OK, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "faccessat with a negative dirfd that is not AT_FDCWD fails with EBADF" {
    const ret = linux.faccessat(-2, "somefile", linux.F_OK, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "faccessat with a regular-file fd as dirfd fails with ENOTDIR" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const ret = linux.faccessat(@intCast(fd), "somefile", linux.F_OK, 0);
    try testing.expectEqual(.NOTDIR, linux.errno(ret));
}

test "faccessat resolves relative to a directory fd" {
    const init = utest.getInit();

    const dir = try std.Io.Dir.openDirAbsolute(
        init.io,
        "/bin",
        .{},
    );
    defer dir.close(init.io);

    const ret = linux.faccessat(@intCast(dir.handle), "utest", linux.F_OK, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
const Test = utest.fs.Test;
