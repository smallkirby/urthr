test "unlinking an open file keeps its data accessible until closed" {
    const init = utest.getInit();
    var t = Test.init();

    const content = "hello-unlink";
    const wfile = try t.createFile();
    try wfile.writeStreamingAll(init.io, content);
    wfile.close(init.io);

    const dir = try std.Io.Dir.openDirAbsolute(
        init.io,
        Test.base_dir,
        .{},
    );
    defer dir.close(init.io);

    const rfile = try dir.openFile(
        init.io,
        Test.file_name,
        .{},
    );
    defer rfile.close(init.io);

    // Remove the directory entry of one file while another file is still open.
    t.deleteFile();

    // The already-open fd must still be able to read back the data.
    var buf: [content.len]u8 = undefined;
    var reader = rfile.reader(init.io, &.{});
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualSlices(u8, content, &buf);

    // Re-opening by name must now fail.
    try testing.expectError(error.FileNotFound, dir.openFile(
        init.io,
        Test.file_name,
        .{},
    ));
}

test "unlinkat a non-existent file fails with ENOENT" {
    const ret = linux.unlinkat(
        linux.AT.FDCWD,
        Test.base_dir ++ "/no-such-file",
        0,
    );
    try testing.expectEqual(.NOENT, linux.errno(ret));
}

test "unlinkat with an unopened dirfd fails with EBADF" {
    const ret = linux.unlinkat(
        999,
        "somefile",
        0,
    );
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "unlinkat a directory fails with EISDIR" {
    const ret = linux.unlinkat(
        linux.AT.FDCWD,
        "/boot/bin",
        0,
    );
    try testing.expectEqual(.ISDIR, linux.errno(ret));
}

test "unlinkat with a regular-file fd as dirfd fails with ENOTDIR" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const ret = linux.unlinkat(@intCast(fd), "somefile", 0);
    try testing.expectEqual(.NOTDIR, linux.errno(ret));
}

test "unlinkat resolves relative to a directory fd" {
    const init = utest.getInit();
    var t = Test.init();

    const wfile = try t.createFile();
    wfile.close(init.io);

    const dir = try std.Io.Dir.openDirAbsolute(
        init.io,
        Test.base_dir,
        .{},
    );
    defer dir.close(init.io);

    const ret = linux.unlinkat(@intCast(dir.handle), Test.file_name, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    try testing.expectError(error.FileNotFound, dir.openFile(
        init.io,
        Test.file_name,
        .{},
    ));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
const Test = utest.fs.Test;
