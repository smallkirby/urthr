test "mkdirat creates a new directory that can be opened" {
    const init = utest.getInit();
    const path = Test.base_dir ++ "mkdir1";

    const ret = linux.mkdirat(linux.AT.FDCWD, path, 0o755);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.rmdir(path);

    var dir = try std.Io.Dir.openDirAbsolute(init.io, path, .{});
    dir.close(init.io);
}

test "mkdirat on an existing directory fails with EEXIST" {
    const path = Test.base_dir ++ "mkdir2";

    const ret1 = linux.mkdirat(linux.AT.FDCWD, path, 0o755);
    try testing.expectEqual(.SUCCESS, linux.errno(ret1));
    defer _ = linux.rmdir(path);

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
    defer _ = linux.rmdir(Test.base_dir ++ "mkdir3");

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
    defer _ = linux.rmdir(path);

    var dir = try std.Io.Dir.openDirAbsolute(init.io, path, .{});
    dir.close(init.io);
}

test "mkdirat resolves the intermediate components of a relative path" {
    const init = utest.getInit();

    const root = try std.Io.Dir.openDirAbsolute(init.io, Test.base_dir, .{});
    defer root.close(init.io);

    try testing.expectEqual(
        .SUCCESS,
        linux.errno(linux.mkdirat(@intCast(root.handle), "mkdir1", 0o755)),
    );
    defer _ = linux.rmdir(Test.base_dir ++ "mkdir1");

    try testing.expectEqual(
        .SUCCESS,
        linux.errno(linux.mkdirat(@intCast(root.handle), "mkdir1/sub", 0o755)),
    );
    defer _ = linux.rmdir(Test.base_dir ++ "mkdir1/sub");

    var created = try std.Io.Dir.openDirAbsolute(
        init.io,
        Test.base_dir ++ "mkdir1/sub",
        .{},
    );
    created.close(init.io);
}

test "mkdirat on a relative path whose parent is missing fails with ENOENT" {
    const init = utest.getInit();

    const root = try std.Io.Dir.openDirAbsolute(init.io, Test.base_dir, .{});
    defer root.close(init.io);

    const rc = linux.mkdirat(@intCast(root.handle), "mkdir1/leaf", 0o755);
    try testing.expectEqual(.NOENT, linux.errno(rc));
}

test "openat O_CREAT with a relative path creates the file under its subdirectory" {
    const init = utest.getInit();

    const root = try std.Io.Dir.openDirAbsolute(init.io, Test.base_dir, .{});
    defer root.close(init.io);

    try testing.expectEqual(
        .SUCCESS,
        linux.errno(linux.mkdirat(@intCast(root.handle), "mkdir1", 0o755)),
    );
    defer _ = linux.rmdir(Test.base_dir ++ "mkdir1");

    try testing.expectEqual(
        .SUCCESS,
        linux.errno(linux.mkdirat(@intCast(root.handle), "mkdir1/sub", 0o755)),
    );
    defer _ = linux.rmdir(Test.base_dir ++ "mkdir1/sub");

    const fd = linux.openat(
        @intCast(root.handle),
        "mkdir1/sub/subsub",
        .{ .ACCMODE = .WRONLY, .CREAT = true },
        0o644,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    _ = linux.close(@intCast(fd));
    defer _ = linux.unlink(Test.base_dir ++ "mkdir1/sub/subsub");

    const reopened = linux.openat(@intCast(root.handle), "mkdir1/sub/subsub", .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(reopened));
    _ = linux.close(@intCast(reopened));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
const Test = utest.fs.Test;
