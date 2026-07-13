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

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
const Test = utest.fs.Test;
