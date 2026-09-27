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

test "syscall: open with a null pathname fails with EFAULT" {
    if (comptime !builtin.cpu.arch.isX86()) return error.SkipZigTest;

    const ret = linux.syscall3(.open, 0, 0, 0);
    try testing.expectEqual(.FAULT, linux.errno(ret));
}

test "syscall: openat with a null pathname fails with EFAULT" {
    const ret = linux.syscall4(.openat, @bitCast(@as(isize, linux.AT.FDCWD)), 0, 0, 0);
    try testing.expectEqual(.FAULT, linux.errno(ret));
}

test "syscall: openat" {
    const init = utest.getInit();

    const boot = try std.Io.Dir.openDirAbsolute(
        init.io,
        Test.base_dir,
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
            Test.base_dir,
            .{ .ACCMODE = .WRONLY },
            0,
        );
        try testing.expectEqual(.ISDIR, linux.errno(ret));
    }

    {
        const ret = linux.openat(
            linux.AT.FDCWD,
            Test.base_dir,
            .{ .ACCMODE = .RDWR },
            0,
        );
        try testing.expectEqual(.ISDIR, linux.errno(ret));
    }
}

test "openat with O_DIRECTORY on a directory succeeds" {
    const ret = linux.openat(
        linux.AT.FDCWD,
        Test.base_dir,
        .{ .DIRECTORY = true },
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.close(@intCast(ret));
}

test "openat with a negative dirfd that is not AT_FDCWD fails with EBADF" {
    const ret = linux.openat(-2, "somefile", .{}, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "openat with a regular file as a non-final path component fails with ENOTDIR" {
    const init = utest.getInit();
    var t = Test.init();

    const file = try t.createFile();
    defer t.deleteFile();
    file.close(init.io);

    const ret = linux.openat(
        linux.AT.FDCWD,
        Test.base_dir ++ "/" ++ Test.file_name ++ "/subpath",
        .{},
        0,
    );
    try testing.expectEqual(.NOTDIR, linux.errno(ret));
}

test "openat to create long filename" {
    const init = utest.getInit();
    const name = "index.html";
    const path = Test.base_dir ++ name;

    // Create a file with a long name.
    const content = "<html></html>";
    {
        const file = try std.Io.Dir.createFileAbsolute(init.io, path, .{});
        defer file.close(init.io);
        try file.writeStreamingAll(init.io, content);
    }
    defer std.Io.Dir.deleteFileAbsolute(init.io, path) catch unreachable;

    // Open the created file.
    const file = try std.Io.Dir.openFileAbsolute(init.io, path, .{});
    defer file.close(init.io);

    // Check if the content is correct.
    var buf: [content.len]u8 = undefined;
    var reader = file.reader(init.io, &.{});
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualSlices(u8, content, &buf);

    // Check if FAT SFN is not exposed.
    const dir = try std.Io.Dir.openDirAbsolute(
        init.io,
        Test.base_dir,
        .{ .iterate = true },
    );
    defer dir.close(init.io);

    var found = false;
    var it = dir.iterateAssumeFirstIteration();
    while (try it.next(init.io)) |ent| {
        if (std.mem.eql(u8, ent.name, name)) found = true;
    }
    try testing.expect(found);
}

test "unlinking a file with a long name and re-creating it" {
    const init = utest.getInit();
    const path = Test.base_dir ++ "index.html";

    // Create and delete a file with a long name.
    {
        const file = try std.Io.Dir.createFileAbsolute(init.io, path, .{});
        file.close(init.io);
        try std.Io.Dir.deleteFileAbsolute(init.io, path);
    }

    // Re-creating a file with the same LFN must succeed.
    {
        const file = try std.Io.Dir.createFileAbsolute(init.io, path, .{});
        file.close(init.io);
        try std.Io.Dir.deleteFileAbsolute(init.io, path);
    }
}

test "openat to create UTF-16 filenames" {
    const init = utest.getInit();

    const names = [_][]const u8{
        "猫",
        "柴犬.txt",
        "鰯",
        "\u{1F600}.txt",
        "😀",
        "🎉🐱🎉",
        "🐱🐱🐱🐱🐱🐱🐱🐱🐱🐱.🐱🐱",
    };

    for (names) |name| {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}{s}", .{ Test.base_dir, name });

        const content = "hello";
        {
            const file = try std.Io.Dir.createFileAbsolute(init.io, path, .{});
            defer file.close(init.io);
            try file.writeStreamingAll(init.io, content);
        }
        defer std.Io.Dir.deleteFileAbsolute(init.io, path) catch unreachable;

        // Can open and read the file.
        const file = try std.Io.Dir.openFileAbsolute(init.io, path, .{});
        defer file.close(init.io);

        var buf: [content.len]u8 = undefined;
        var reader = file.reader(init.io, &.{});
        try reader.interface.readSliceAll(&buf);
        try testing.expectEqualSlices(u8, content, &buf);

        // Exposed name is correct.
        const dir = try std.Io.Dir.openDirAbsolute(
            init.io,
            Test.base_dir,
            .{ .iterate = true },
        );
        defer dir.close(init.io);

        var found = false;
        var it = dir.iterateAssumeFirstIteration();
        while (try it.next(init.io)) |ent| {
            if (std.mem.eql(u8, ent.name, name)) found = true;
        }
        try testing.expect(found);
    }
}

test "O_APPEND write always appends to the end of the file" {
    const init = utest.getInit();
    var t = Test.init();

    {
        const file = try t.createFile();
        defer file.close(init.io);
        try file.writeStreamingAll(init.io, "0123456789");
    }
    defer t.deleteFile();

    const fd = linux.openat(
        linux.AT.FDCWD,
        Test.base_dir ++ "/" ++ Test.file_name,
        .{ .ACCMODE = .WRONLY, .APPEND = true },
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    // Seek back to the beginning.
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.lseek(@intCast(fd), 0, linux.SEEK.SET),
    ));

    // Write to the file that should always append to the end.
    const appended = "abc";
    try testing.expectEqual(
        @as(usize, appended.len),
        linux.write(@intCast(fd), appended, appended.len),
    );

    const read_fd = linux.openat(linux.AT.FDCWD, Test.base_dir ++ "/" ++ Test.file_name, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(read_fd));
    defer _ = linux.close(@intCast(read_fd));

    var buf: [13]u8 = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.read(@intCast(read_fd), &buf, buf.len),
    ));
    try testing.expectEqualSlices(u8, "0123456789" ++ appended, &buf);
}

test "openat with O_CLOEXEC sets FD_CLOEXEC on the returned fd" {
    const fd = linux.openat(
        linux.AT.FDCWD,
        utest.myname,
        .{ .CLOEXEC = true },
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const FD_CLOEXEC = 1;
    const got = linux.fcntl(@intCast(fd), linux.F.GETFD, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(got));
    try testing.expectEqual(FD_CLOEXEC, got);
}

test "openat with O_NONBLOCK is reflected in F_GETFL" {
    const fd = linux.openat(
        linux.AT.FDCWD,
        utest.myname,
        .{ .NONBLOCK = true },
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const O_NONBLOCK = 0o4000;
    const got = linux.fcntl(@intCast(fd), linux.F.GETFL, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(got));
    try testing.expect(got & O_NONBLOCK != 0);
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
const builtin = @import("builtin");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
const Test = utest.fs.Test;
