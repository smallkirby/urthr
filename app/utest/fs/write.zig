test "syscall: write" {
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

    const content = "urthr";
    const ret = linux.write(@intCast(fd), content, content.len);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(@as(usize, content.len), ret);
}

test "write with an unopened fd fails with EBADF" {
    const content = "urthr";
    const ret = linux.write(999, content, content.len);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "write with a negative fd fails with EBADF" {
    const content = "urthr";
    const ret = linux.write(-1, content, content.len);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "writing to a directory fd fails with EBADF" {
    const fd = linux.openat(
        linux.AT.FDCWD,
        "/boot",
        .{},
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const content = "x";
    const ret = linux.write(@intCast(fd), content, content.len);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "writing to a read-only-opened file fails with EBADF" {
    const init = utest.getInit();
    var t = Test.init();

    const wfile = try t.createFile();
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

    const content = "x";
    const ret = linux.write(@intCast(fd), content, content.len);
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
