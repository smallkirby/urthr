test "syscall: read" {
    const init = utest.getInit();

    const file = try std.Io.Dir.openFileAbsolute(
        init.io,
        utest.myname,
        .{},
    );
    defer file.close(init.io);

    var buf: [4]u8 = undefined;
    const ret = linux.read(file.handle, &buf, buf.len);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqualSlices(u8, std.elf.MAGIC, &buf);
}

test "with an unopened fd fails with EBADF" {
    var buf: [4]u8 = undefined;
    const ret = linux.read(999, &buf, buf.len);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "with a negative fd fails with EBADF" {
    var buf: [4]u8 = undefined;
    const ret = linux.read(-1, &buf, buf.len);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "reading from a directory fd fails with EISDIR" {
    const fd = linux.openat(linux.AT.FDCWD, "/boot", .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    var buf: [4]u8 = undefined;
    const ret = linux.read(@intCast(fd), &buf, buf.len);
    try testing.expectEqual(.ISDIR, linux.errno(ret));
}

test "reading from a write-only-opened file fails with EBADF" {
    const init = utest.getInit();
    var t = Test.init();

    const wfile = try t.createFile();
    wfile.close(init.io);
    defer t.deleteFile();

    const fd = linux.openat(
        linux.AT.FDCWD,
        Test.base_dir ++ "/" ++ Test.file_name,
        .{ .ACCMODE = .WRONLY },
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    var buf: [4]u8 = undefined;
    const ret = linux.read(@intCast(fd), &buf, buf.len);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
const Test = utest.fs.Test;
