const name_file1 = "file1";
const name_file2 = "file2";
const name_dir1 = "dir1";
const name_dir2 = "dir2";
const name_subdir1 = "subdir1";
const name_noexist = "does-not-exist";

const content_a = "content-a";
const content_b = "content-b";

test "renameat moves a file to a new name in the same directory" {
    const init = utest.getInit();
    try createWith(init, name_file1, content_a);

    const ret = linux.renameat(
        linux.AT.FDCWD,
        Test.base_dir ++ name_file1,
        linux.AT.FDCWD,
        Test.base_dir ++ name_file2,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.unlinkat(linux.AT.FDCWD, Test.base_dir ++ name_file2, 0);

    const dir = try std.Io.Dir.openDirAbsolute(init.io, Test.base_dir, .{});
    defer dir.close(init.io);
    try testing.expectError(
        error.FileNotFound,
        dir.openFile(init.io, name_file1, .{}),
    );

    var buf: [32]u8 = undefined;
    const read = try readAll(init, name_file2, &buf);
    try testing.expectEqualSlices(u8, content_a, read);
}

test "renameat replaces an existing destination file" {
    const init = utest.getInit();
    try createWith(init, name_file1, content_a);
    try createWith(init, name_file2, content_b);

    const ret = linux.renameat(
        linux.AT.FDCWD,
        Test.base_dir ++ name_file1,
        linux.AT.FDCWD,
        Test.base_dir ++ name_file2,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.unlinkat(linux.AT.FDCWD, Test.base_dir ++ name_file2, 0);

    const dir = try std.Io.Dir.openDirAbsolute(init.io, Test.base_dir, .{});
    defer dir.close(init.io);
    try testing.expectError(
        error.FileNotFound,
        dir.openFile(init.io, name_file1, .{}),
    );

    var buf: [32]u8 = undefined;
    const content = try readAll(init, name_file2, &buf);
    try testing.expectEqualSlices(u8, content_a, content);
}

test "renameat onto itself is a no-op and succeeds" {
    const init = utest.getInit();
    try createWith(init, name_file1, content_a);
    defer _ = linux.unlinkat(linux.AT.FDCWD, Test.base_dir ++ name_file1, 0);

    const ret = linux.renameat(
        linux.AT.FDCWD,
        Test.base_dir ++ name_file1,
        linux.AT.FDCWD,
        Test.base_dir ++ name_file1,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    var buf: [32]u8 = undefined;
    const read = try readAll(init, name_file1, &buf);
    try testing.expectEqualSlices(u8, content_a, read);
}

test "renameat can rename a directory" {
    const init = utest.getInit();

    const mkret = linux.mkdirat(linux.AT.FDCWD, Test.base_dir ++ name_dir1, 0o755);
    try testing.expectEqual(.SUCCESS, linux.errno(mkret));

    const ret = linux.renameat(
        linux.AT.FDCWD,
        Test.base_dir ++ name_dir1,
        linux.AT.FDCWD,
        Test.base_dir ++ name_dir2,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.rmdir(Test.base_dir ++ name_dir2);

    const dir = try std.Io.Dir.openDirAbsolute(init.io, Test.base_dir, .{});
    defer dir.close(init.io);
    try testing.expectError(
        error.FileNotFound,
        dir.openDir(init.io, name_dir1, .{}),
    );

    var moved = try std.Io.Dir.openDirAbsolute(init.io, Test.base_dir ++ name_dir2, .{});
    moved.close(init.io);
}

test "renameat rejects moving a directory into its own subdirectory" {
    const mkret = linux.mkdirat(linux.AT.FDCWD, Test.base_dir ++ name_dir1, 0o755);
    try testing.expectEqual(.SUCCESS, linux.errno(mkret));

    const parent_fd = linux.open(Test.base_dir ++ name_dir1, .{ .DIRECTORY = true }, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(parent_fd));
    defer _ = linux.close(@intCast(parent_fd));

    const subret = linux.mkdirat(@intCast(parent_fd), name_subdir1, 0o755);
    try testing.expectEqual(.SUCCESS, linux.errno(subret));

    const sub_fd = linux.openat(@intCast(parent_fd), name_subdir1, .{ .DIRECTORY = true }, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(sub_fd));
    defer _ = linux.close(@intCast(sub_fd));

    const ret = linux.renameat(
        linux.AT.FDCWD,
        Test.base_dir ++ name_dir1,
        @intCast(sub_fd),
        name_noexist,
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));

    // cleanup
    const rmsub = linux.unlinkat(@intCast(parent_fd), name_subdir1, linux.AT.REMOVEDIR);
    try testing.expectEqual(.SUCCESS, linux.errno(rmsub));
    const rmdir_ret = linux.rmdir(Test.base_dir ++ name_dir1);
    try testing.expectEqual(.SUCCESS, linux.errno(rmdir_ret));
}

test "renameat fails with EISDIR when the destination is a directory while the source is not" {
    const init = utest.getInit();
    try createWith(init, name_file1, content_a);
    defer _ = linux.unlinkat(linux.AT.FDCWD, Test.base_dir ++ name_file1, 0);

    const mkret = linux.mkdirat(linux.AT.FDCWD, Test.base_dir ++ name_dir2, 0o755);
    try testing.expectEqual(.SUCCESS, linux.errno(mkret));
    defer _ = linux.rmdir(Test.base_dir ++ name_dir2);

    const ret = linux.renameat(
        linux.AT.FDCWD,
        Test.base_dir ++ name_file1,
        linux.AT.FDCWD,
        Test.base_dir ++ name_dir2,
    );
    try testing.expectEqual(.ISDIR, linux.errno(ret));
}

test "renameat fails with ENOTDIR when the source is a directory while the destination is not" {
    const init = utest.getInit();
    try createWith(init, name_file1, content_a);
    defer _ = linux.unlinkat(linux.AT.FDCWD, Test.base_dir ++ name_file1, 0);

    const mkret = linux.mkdirat(linux.AT.FDCWD, Test.base_dir ++ name_dir2, 0o755);
    try testing.expectEqual(.SUCCESS, linux.errno(mkret));
    defer _ = linux.rmdir(Test.base_dir ++ name_dir2);

    const ret = linux.renameat(
        linux.AT.FDCWD,
        Test.base_dir ++ name_dir2,
        linux.AT.FDCWD,
        Test.base_dir ++ name_file1,
    );
    try testing.expectEqual(.NOTDIR, linux.errno(ret));
}

test "renameat resolves relative to directory fds" {
    const init = utest.getInit();
    try createWith(init, name_file1, content_a);

    const dir = try std.Io.Dir.openDirAbsolute(init.io, Test.base_dir, .{});
    defer dir.close(init.io);

    const ret = linux.renameat(
        @intCast(dir.handle),
        name_file1,
        @intCast(dir.handle),
        name_file2,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.unlinkat(linux.AT.FDCWD, Test.base_dir ++ name_file2, 0);

    var buf: [32]u8 = undefined;
    const content = try readAll(init, name_file2, &buf);
    try testing.expectEqualSlices(u8, content_a, content);
}

test "renameat a non-existent source fails with ENOENT" {
    const ret = linux.renameat(
        linux.AT.FDCWD,
        Test.base_dir ++ name_noexist,
        linux.AT.FDCWD,
        Test.base_dir ++ name_file2,
    );
    try testing.expectEqual(.NOENT, linux.errno(ret));
}

test "renameat with an unopened old dirfd fails with EBADF" {
    const ret = linux.renameat(999, name_file1, linux.AT.FDCWD, name_file2);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "renameat with an unopened new dirfd fails with EBADF" {
    const init = utest.getInit();
    try createWith(init, name_file1, content_a);
    defer _ = linux.unlinkat(linux.AT.FDCWD, Test.base_dir ++ name_file1, 0);

    const ret = linux.renameat(linux.AT.FDCWD, Test.base_dir ++ name_file1, 999, name_file2);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "renameat2 with RENAME_NOREPLACE fails with EEXIST when the destination exists" {
    const init = utest.getInit();
    try createWith(init, name_file1, content_a);
    defer _ = linux.unlinkat(linux.AT.FDCWD, Test.base_dir ++ name_file1, 0);
    try createWith(init, name_file2, content_b);
    defer _ = linux.unlinkat(linux.AT.FDCWD, Test.base_dir ++ name_file2, 0);

    const ret = linux.renameat2(
        linux.AT.FDCWD,
        Test.base_dir ++ name_file1,
        linux.AT.FDCWD,
        Test.base_dir ++ name_file2,
        .{ .NOREPLACE = true },
    );
    try testing.expectEqual(.EXIST, linux.errno(ret));

    // Nothing should have changed.
    var buf: [32]u8 = undefined;
    const content = try readAll(init, name_file2, &buf);
    try testing.expectEqualSlices(u8, content_b, content);
}

test "rename moves a file" {
    const init = utest.getInit();
    try createWith(init, name_file1, content_a);

    const ret = linux.rename(Test.base_dir ++ name_file1, Test.base_dir ++ name_file2);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.unlinkat(linux.AT.FDCWD, Test.base_dir ++ name_file2, 0);

    var buf: [32]u8 = undefined;
    const content = try readAll(init, name_file2, &buf);
    try testing.expectEqualSlices(u8, content_a, content);
}

// =============================================================
// Helpers
// =============================================================

/// Create a file with the given name under `Test.base_dir` and write `content` to it.
fn createWith(init: anytype, name: []const u8, content: []const u8) !void {
    const dir = try std.Io.Dir.openDirAbsolute(init.io, Test.base_dir, .{});
    defer dir.close(init.io);

    const file = try dir.createFile(init.io, name, .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, content);
}

/// Read the whole content of the file with the given name under `Test.base_dir`.
fn readAll(init: anytype, name: []const u8, buf: []u8) ![]u8 {
    const dir = try std.Io.Dir.openDirAbsolute(init.io, Test.base_dir, .{});
    defer dir.close(init.io);

    const file = try dir.openFile(init.io, name, .{});
    defer file.close(init.io);

    var reader = file.reader(init.io, &.{});
    const n = try reader.interface.readSliceShort(buf);
    return buf[0..n];
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
const Test = utest.fs.Test;
