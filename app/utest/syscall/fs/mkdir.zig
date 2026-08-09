test "mkdirat creates a new directory that can be opened" {
    const init = utest.getInit();
    const path = Test.base_dir ++ "mkdir1";

    const ret = linux.mkdirat(linux.AT.FDCWD, path, 0o755);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    var dir = try std.Io.Dir.openDirAbsolute(init.io, path, .{});
    dir.close(init.io);
}

test "mkdirat on an existing directory fails with EEXIST" {
    const path = Test.base_dir ++ "mkdir2";

    const ret1 = linux.mkdirat(linux.AT.FDCWD, path, 0o755);
    try testing.expectEqual(.SUCCESS, linux.errno(ret1));

    const ret2 = linux.mkdirat(linux.AT.FDCWD, path, 0o755);
    try testing.expectEqual(.EXIST, linux.errno(ret2));
}

test "mkdirat with an unopened dirfd fails with EBADF" {
    const ret = linux.mkdirat(999, "somedir1", 0o755);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "mkdirat with a regular-file fd as dirfd fails with ENOTDIR" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const ret = linux.mkdirat(@intCast(fd), "somedir1", 0o755);
    try testing.expectEqual(.NOTDIR, linux.errno(ret));
}

test "mkdirat resolves relative to a directory fd" {
    const init = utest.getInit();

    const dir = try std.Io.Dir.openDirAbsolute(init.io, Test.base_dir, .{});
    defer dir.close(init.io);

    const ret = linux.mkdirat(@intCast(dir.handle), "mkdir3", 0o755);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    var created = try std.Io.Dir.openDirAbsolute(
        init.io,
        Test.base_dir ++ "mkdir3",
        .{},
    );
    created.close(init.io);
}

test "mkdir creates a new directory" {
    const init = utest.getInit();
    const path = Test.base_dir ++ "mkdirt4";

    const ret = linux.mkdir(path, 0o755);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    var dir = try std.Io.Dir.openDirAbsolute(init.io, path, .{});
    dir.close(init.io);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
const Test = utest.fs.Test;
