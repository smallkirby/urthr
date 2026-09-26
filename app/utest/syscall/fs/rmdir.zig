const dir_name = "dir1";
const file_name = "file1";
const nested_name = "sub1";
const noexist_name = "does-not-exist";

test "rmdir removes an empty directory" {
    const init = utest.getInit();

    const mkret = linux.mkdirat(linux.AT.FDCWD, Test.base_dir ++ dir_name, 0o755);
    try testing.expectEqual(.SUCCESS, linux.errno(mkret));

    const ret = linux.rmdir(Test.base_dir ++ dir_name);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    const dir = try std.Io.Dir.openDirAbsolute(init.io, Test.base_dir, .{});
    defer dir.close(init.io);
    try testing.expectError(
        error.FileNotFound,
        dir.openDir(init.io, dir_name, .{}),
    );
}

test "rmdir fails with ENOTEMPTY when the directory has entries" {
    const mkparent = linux.mkdirat(linux.AT.FDCWD, Test.base_dir ++ dir_name, 0o755);
    try testing.expectEqual(.SUCCESS, linux.errno(mkparent));

    const parent_fd = linux.open(Test.base_dir ++ dir_name, .{ .DIRECTORY = true }, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(parent_fd));
    defer _ = linux.close(@intCast(parent_fd));

    const mkret = linux.mkdirat(@intCast(parent_fd), nested_name, 0o755);
    try testing.expectEqual(.SUCCESS, linux.errno(mkret));

    const ret = linux.rmdir(Test.base_dir ++ dir_name);
    try testing.expectEqual(.NOTEMPTY, linux.errno(ret));

    // cleanup
    const subret = linux.unlinkat(@intCast(parent_fd), nested_name, linux.AT.REMOVEDIR);
    try testing.expectEqual(.SUCCESS, linux.errno(subret));
    const cleanup = linux.rmdir(Test.base_dir ++ dir_name);
    try testing.expectEqual(.SUCCESS, linux.errno(cleanup));
}

test "rmdir fails with ENOTDIR when the target is not a directory" {
    const init = utest.getInit();
    const dir = try std.Io.Dir.openDirAbsolute(init.io, Test.base_dir, .{});
    defer dir.close(init.io);
    const file = try dir.createFile(init.io, file_name, .{});
    file.close(init.io);
    defer _ = linux.unlinkat(linux.AT.FDCWD, Test.base_dir ++ file_name, 0);

    const ret = linux.rmdir(Test.base_dir ++ file_name);
    try testing.expectEqual(.NOTDIR, linux.errno(ret));
}

test "rmdir a non-existent path fails with ENOENT" {
    const ret = linux.rmdir(Test.base_dir ++ noexist_name);
    try testing.expectEqual(.NOENT, linux.errno(ret));
}

test "rmdir fails with EINVAL when the last component is dot" {
    const mkret = linux.mkdirat(linux.AT.FDCWD, Test.base_dir ++ dir_name, 0o755);
    try testing.expectEqual(.SUCCESS, linux.errno(mkret));

    const ret = linux.rmdir(Test.base_dir ++ dir_name ++ "/.");
    try testing.expectEqual(.INVAL, linux.errno(ret));

    const cleanup = linux.rmdir(Test.base_dir ++ dir_name);
    try testing.expectEqual(.SUCCESS, linux.errno(cleanup));
}

test "rmdir fails with EBUSY when removing the filesystem root" {
    const ret = linux.rmdir("/"); // horrifying... XD
    try testing.expectEqual(.BUSY, linux.errno(ret));
}

test "cwd inside a removed directory tree keeps working" {
    const parent = Test.base_dir ++ "pdir1";
    const child = parent ++ "/cdir1";
    const tmp = Test.base_dir ++ "tmp1";

    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.mkdirat(linux.AT.FDCWD, parent, 0o755),
    ));
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.mkdirat(linux.AT.FDCWD, child, 0o755),
    ));
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.chdir(child),
    ));
    defer _ = linux.chdir(Test.base_dir);

    // Remove the child and parent while CWD is inside the child.
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.rmdir(child),
    ));
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.rmdir(parent),
    ));

    // Churn directory entries so that a freed ancestor is likely be reused.
    for (0..4) |_| {
        try testing.expectEqual(.SUCCESS, linux.errno(
            linux.mkdirat(linux.AT.FDCWD, tmp, 0o755),
        ));
        try testing.expectEqual(.SUCCESS, linux.errno(
            linux.rmdir(tmp),
        ));
    }

    // Behavior of ".." and getcwd() here is unspecified.
    const rc = linux.chdir("..");
    try testing.expect(linux.errno(rc) == .SUCCESS or linux.errno(rc) == .NOENT);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = linux.getcwd(&buf, buf.len);
}

test "unlinkat with AT_REMOVEDIR removes an empty directory relative to a directory fd" {
    const init = utest.getInit();
    const dir = try std.Io.Dir.openDirAbsolute(init.io, Test.base_dir, .{});
    defer dir.close(init.io);

    const mkret = linux.mkdirat(@intCast(dir.handle), dir_name, 0o755);
    try testing.expectEqual(.SUCCESS, linux.errno(mkret));

    const ret = linux.unlinkat(@intCast(dir.handle), dir_name, linux.AT.REMOVEDIR);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    try testing.expectError(
        error.FileNotFound,
        dir.openDir(init.io, dir_name, .{}),
    );
}

test "unlinkat with AT_REMOVEDIR and an unopened dirfd fails with EBADF" {
    const ret = linux.unlinkat(999, dir_name, linux.AT.REMOVEDIR);
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
