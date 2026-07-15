// =============================================================
// fstat

test "syscall: fstat" {
    const init = utest.getInit();
    var t = Test.init();

    const content = "0123456789";
    const file = try t.createFile();
    defer t.deleteFile();
    defer file.close(utest.getInit().io);
    try file.writeStreamingAll(init.io, content);

    var statbuf: [4096]u8 = undefined;
    try testing.expectEqual(0, std.os.linux.syscall2(
        .fstat,
        @intCast(file.handle),
        @intFromPtr(&statbuf),
    ));

    const stat: *const Stat = @ptrCast(@alignCast(&statbuf));
    try testing.expectEqual(0, stat.st_uid);
    try testing.expectEqual(0, stat.st_gid);
    try testing.expectEqual(512, stat.st_blksize);
    try testing.expectEqual(content.len, @as(usize, @intCast(stat.st_size)));
    try testing.expect(0 != stat.st_ino);
}

test "fstat with an unopened fd fails with EBADF" {
    var statbuf: [4096]u8 = undefined;
    const ret = std.os.linux.syscall2(.fstat, 999, @intFromPtr(&statbuf));
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "fstatat a non-existent file fails with ENOENT" {
    var statbuf: [4096]u8 align(8) = undefined;
    const ret = std.os.linux.syscall4(
        .fstatat64,
        @bitCast(@as(isize, linux.AT.FDCWD)),
        @intFromPtr((Test.base_dir ++ "/no-such-file").ptr),
        @intFromPtr(&statbuf),
        0,
    );
    try testing.expectEqual(.NOENT, linux.errno(ret));
}

test "fstatat with an unopened dirfd fails with EBADF" {
    var statbuf: [4096]u8 align(8) = undefined;
    const ret = std.os.linux.syscall4(
        .fstatat64,
        999,
        @intFromPtr("somefile".ptr),
        @intFromPtr(&statbuf),
        0,
    );
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "fstatat with a regular-file fd as dirfd fails with ENOTDIR" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    var statbuf: [4096]u8 align(8) = undefined;
    const ret = std.os.linux.syscall4(
        .fstatat64,
        @intCast(fd),
        @intFromPtr("somefile".ptr),
        @intFromPtr(&statbuf),
        0,
    );
    try testing.expectEqual(.NOTDIR, linux.errno(ret));
}

test "fstatat via a directory fd with a relative pathname succeeds" {
    const init = utest.getInit();

    const dir = try std.Io.Dir.openDirAbsolute(
        init.io,
        "/boot",
        .{},
    );
    defer dir.close(init.io);

    var statbuf: [4096]u8 align(8) = undefined;
    const ret = std.os.linux.syscall4(
        .fstatat64,
        @intCast(dir.handle),
        @intFromPtr("bin".ptr),
        @intFromPtr(&statbuf),
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    const stat: *const Stat = @ptrCast(@alignCast(&statbuf));
    try testing.expect(0 != stat.st_ino);
}

test "fstatat with AT_EMPTY_PATH and an empty pathname stats the dirfd itself" {
    const AT_EMPTY_PATH = 0x1000;

    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    var statbuf: [4096]u8 align(8) = undefined;
    const ret = std.os.linux.syscall4(
        .fstatat64,
        @intCast(fd),
        @intFromPtr("".ptr),
        @intFromPtr(&statbuf),
        AT_EMPTY_PATH,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    const stat: *const Stat = @ptrCast(@alignCast(&statbuf));
    try testing.expect(0 != stat.st_ino);
}

// =============================================================
// getdents

test "getdents64 on a regular file fails with ENOTDIR" {
    const init = utest.getInit();

    const file = try std.Io.Dir.openFileAbsolute(
        init.io,
        utest.myname,
        .{},
    );
    defer file.close(init.io);

    var buf: [256]u8 = undefined;
    const ret = linux.getdents64(@intCast(file.handle), &buf, buf.len);
    try testing.expectEqual(.NOTDIR, linux.errno(ret));
}

test "getdents64 with an unopened fd fails with EBADF" {
    var buf: [256]u8 = undefined;
    const ret = linux.getdents64(999, &buf, buf.len);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "getdents64 with a negative fd fails with EBADF" {
    var buf: [256]u8 = undefined;
    const ret = linux.getdents64(-1, &buf, buf.len);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "getdents64 with a buffer too small for a single entry fails with EINVAL" {
    const init = utest.getInit();

    const dir = try std.Io.Dir.openDirAbsolute(
        init.io,
        "/boot/bin",
        .{ .iterate = true },
    );
    defer dir.close(init.io);

    var buf: [1]u8 = undefined;
    const ret = linux.getdents64(@intCast(dir.handle), &buf, buf.len);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

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

const Stat = extern struct {
    /// Device ID.
    st_dev: u64,
    /// Inode number.
    st_ino: u64,
    /// File mode.
    st_mode: u32,
    /// Number of hard links.
    st_nlink: u32,
    /// User ID of owner.
    st_uid: u32,
    /// Group ID of owner.
    st_gid: u32,
    /// Device ID (if special file).
    st_rdev: u64,
    /// Total size, in bytes.
    st_size: i64,
    /// Block size for filesystem I/O.
    st_blksize: i64,
    /// Number of 512B blocks allocated.
    st_blocks: i64,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
const Test = utest.fs.Test;
