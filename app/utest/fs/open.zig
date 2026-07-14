test "syscall: open" {
    const ret = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.close(@intCast(ret));
}

test "open and read regular file" {
    const init = utest.getInit();

    const file = try std.Io.Dir.openFileAbsolute(
        init.io,
        utest.myname,
        .{},
    );
    defer file.close(init.io);

    var magic: [4]u8 = undefined;
    var reader = file.reader(init.io, &.{});
    try reader.interface.readSliceAll(&magic);

    try testing.expectEqualSlices(u8, std.elf.MAGIC, &magic);
}

test "try to open a non-existent file" {
    const init = utest.getInit();

    try testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(
        init.io,
        Test.base_dir ++ "/no-such-file",
        .{},
    ));
}

test "syscall: openat" {
    const init = utest.getInit();

    const boot = try std.Io.Dir.openDirAbsolute(
        init.io,
        "/boot",
        .{},
    );
    defer boot.close(init.io);

    const ret = linux.openat(
        boot.handle,
        "bin",
        .{},
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.close(@intCast(ret));
}

test "openat resolves relative to a directory fd" {
    const init = utest.getInit();
    var t = Test.init();

    const content = "0123456789";
    {
        const file = try t.createFile();
        defer file.close(utest.getInit().io);
        try file.writeStreamingAll(init.io, content);
    }

    {
        defer t.deleteFile();

        const dir = try std.Io.Dir.openDirAbsolute(
            init.io,
            Test.base_dir,
            .{},
        );
        defer dir.close(init.io);

        const file = try dir.openFile(init.io, Test.file_name, .{});
        defer file.close(init.io);

        var buf: [content.len]u8 = undefined;
        var reader = file.reader(init.io, &.{});
        try reader.interface.readSliceAll(&buf);
        try testing.expectEqualSlices(u8, content, &buf);
    }
}

test "openat with an unopened dirfd fails with EBADF" {
    const ret = linux.openat(999, "somefile", .{}, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "openat with a regular-file fd as dirfd fails with ENOTDIR" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const ret = linux.openat(@intCast(fd), "somefile", .{}, 0);
    try testing.expectEqual(.NOTDIR, linux.errno(ret));
}

test "openat with O_DIRECTORY on a regular file fails with ENOTDIR" {
    const ret = linux.openat(
        linux.AT.FDCWD,
        utest.myname,
        .{ .DIRECTORY = true },
        0,
    );
    try testing.expectEqual(.NOTDIR, linux.errno(ret));
}

test "opening a directory with write access fails with EISDIR" {
    {
        const ret = linux.openat(
            linux.AT.FDCWD,
            "/boot",
            .{ .ACCMODE = .WRONLY },
            0,
        );
        try testing.expectEqual(.ISDIR, linux.errno(ret));
    }

    {
        const ret = linux.openat(
            linux.AT.FDCWD,
            "/boot",
            .{ .ACCMODE = .RDWR },
            0,
        );
        try testing.expectEqual(.ISDIR, linux.errno(ret));
    }
}

test "openat with O_CREAT and O_EXCL on an existing file fails with EEXIST" {
    const init = utest.getInit();
    var t = Test.init();

    const file = try t.createFile();
    defer t.deleteFile();
    file.close(init.io);

    const ret = linux.openat(
        linux.AT.FDCWD,
        Test.base_dir ++ "/" ++ Test.file_name,
        .{ .CREAT = true, .EXCL = true },
        0,
    );
    try testing.expectEqual(.EXIST, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
const Test = utest.fs.Test;
