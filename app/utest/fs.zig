const Test = struct {
    const Self = @This();

    /// Base directory name.
    const base_dir = "/boot";
    /// Name of the test file.
    const file_name = "test.txt";

    pub fn init() Self {
        return .{};
    }

    pub fn createFile(_: *const Self) !std.Io.File {
        const ini = utest.getInit();

        const dir = try std.Io.Dir.openDirAbsolute(
            ini.io,
            base_dir,
            .{},
        );
        defer dir.close(ini.io);

        return try dir.createFile(ini.io, file_name, .{});
    }

    // TODO: need to implement unlinkat syscall.
    pub fn deleteFile(_: *const Self) void {
        const ini = utest.getInit();

        const dir = std.Io.Dir.openDirAbsolute(
            ini.io,
            base_dir,
            .{},
        ) catch |err| {
            std.log.err("Failed to open base directory: {t}", .{err});
            std.process.exit(1);
        };
        defer dir.close(ini.io);

        dir.deleteFile(ini.io, file_name) catch |err| {
            std.log.err("Failed to delete test file: {t}", .{err});
            std.process.exit(1);
        };
    }
};

// =============================================================
// open

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
    // TODO: once deleteFile() is implemented, uncomment this.
    return error.SkipZigTest;

    //const init = utest.getInit();
    //var t = Test.init();

    //const content = "0123456789";
    //{
    //    const file = try t.createFile();
    //    defer file.close(utest.getInit().io);
    //    try file.writeStreamingAll(init.io, content);
    //}

    //{
    //    defer t.deleteFile();

    //    const dir = try std.Io.Dir.openDirAbsolute(
    //        init.io,
    //        Test.base_dir,
    //        .{},
    //    );
    //    defer dir.close(init.io);

    //    const file = try dir.openFile(init.io, Test.file_name, .{});
    //    defer file.close(init.io);

    //    var buf: [content.len]u8 = undefined;
    //    var reader = file.reader(init.io, &.{});
    //    try reader.interface.readSliceAll(&buf);
    //    try testing.expectEqualSlices(u8, content, &buf);
    //}
}

// =============================================================
// read

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

// =============================================================
// write

test "syscall: write" {
    const init = utest.getInit();

    const file = try std.Io.Dir.openFileAbsolute(
        init.io,
        utest.myname,
        .{},
    );
    defer file.close(init.io);

    const content = "urthr";
    const ret = linux.write(file.handle, content, content.len);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(@as(usize, content.len), ret);
}

// =============================================================
// stat

test "syscall: fstat" {
    // TODO: once deleteFile() is implemented, uncomment this.
    return error.SkipZigTest;

    //const init = utest.getInit();
    //var t = Test.init();

    //const content = "0123456789";
    //const file = try t.createFile();
    //defer t.deleteFile();
    //defer file.close(utest.getInit().io);
    //try file.writeStreamingAll(init.io, content);

    //var statbuf: [4096]u8 = undefined;
    //try testing.expectEqual(0, std.os.linux.syscall2(
    //    .fstat,
    //    @intCast(file.handle),
    //    @intFromPtr(&statbuf),
    //));
    //std.log.debug("fuga", .{});

    //const Stat = extern struct {
    //    /// Device ID.
    //    st_dev: u64,
    //    /// Inode number.
    //    st_ino: u64,
    //    /// File mode.
    //    st_mode: u32,
    //    /// Number of hard links.
    //    st_nlink: u32,
    //    /// User ID of owner.
    //    st_uid: u32,
    //    /// Group ID of owner.
    //    st_gid: u32,
    //    /// Device ID (if special file).
    //    st_rdev: u64,
    //    /// Total size, in bytes.
    //    st_size: i64,
    //    /// Block size for filesystem I/O.
    //    st_blksize: i64,
    //    /// Number of 512B blocks allocated.
    //    st_blocks: i64,
    //};
    //const stat: *const Stat = @ptrCast(@alignCast(&statbuf));
    //try testing.expectEqual(0, stat.st_uid);
    //try testing.expectEqual(0, stat.st_gid);
    //try testing.expectEqual(512, stat.st_blksize);
    //try testing.expectEqual(content.len, @as(usize, @intCast(stat.st_size)));
    //try testing.expect(0 != stat.st_ino);
}

// =============================================================
// getdents

test "getdents64 can find myself in /boot/bin" {
    const init = utest.getInit();

    const dir = try std.Io.Dir.openDirAbsolute(
        init.io,
        "/boot/bin",
        .{ .iterate = true },
    );
    defer dir.close(init.io);

    var saw_utest = false;
    var it = dir.iterateAssumeFirstIteration();
    while (try it.next(init.io)) |ent| {
        if (std.mem.eql(u8, ent.name, "utest")) saw_utest = true;
    }

    try testing.expect(saw_utest);
}

// =============================================================
// chdir

test "chdir" {
    var oldbuf: [std.fs.max_path_bytes]u8 = undefined;
    var newbuf: [std.fs.max_path_bytes]u8 = undefined;

    const current = try getcwd(&oldbuf);
    defer chdir(current) catch unreachable;

    const target = Test.base_dir ++ "/bin";
    try chdir(target);
    try testing.expectEqualSlices(u8, target, try getcwd(&newbuf));
}

// =============================================================
// Helpers
// =============================================================

fn getcwd(buf: []u8) ![:0]const u8 {
    const rc = linux.getcwd(buf.ptr, buf.len);
    try testing.expectEqual(.SUCCESS, linux.errno(rc));
    return buf[0..std.mem.span(@as([*:0]u8, @ptrCast(buf.ptr))).len :0];
}

fn chdir(path: [:0]const u8) !void {
    const rc = linux.chdir(path.ptr);
    try testing.expectEqual(.SUCCESS, linux.errno(rc));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest.zig");
