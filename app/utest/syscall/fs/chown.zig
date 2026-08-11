test "syscall: fchown" {
    const init = utest.getInit();
    var t = Test.init();

    const file = try t.createFile();
    defer t.deleteFile();
    defer file.close(init.io);

    const ret = linux.fchown(@intCast(file.handle), 42, 43);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    const stat = try fstat(file.handle);
    try testing.expectEqual(42, stat.st_uid);
    try testing.expectEqual(43, stat.st_gid);
}

test "fchown with owner or group set to -1 leaves that ID unchanged" {
    const init = utest.getInit();
    var t = Test.init();

    const file = try t.createFile();
    defer t.deleteFile();
    defer file.close(init.io);

    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.fchown(@intCast(file.handle), 42, 43),
    ));
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.fchown(@intCast(file.handle), @bitCast(@as(i32, -1)), @bitCast(@as(i32, -1))),
    ));

    const stat = try fstat(file.handle);
    try testing.expectEqual(42, stat.st_uid);
    try testing.expectEqual(43, stat.st_gid);
}

test "fchown with an unopened fd fails with EBADF" {
    const ret = linux.fchown(999, 0, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

// =============================================================
// fchownat

test "syscall: fchownat" {
    const init = utest.getInit();
    var t = Test.init();

    const file = try t.createFile();
    defer t.deleteFile();
    defer file.close(init.io);

    const ret = linux.fchownat(
        linux.AT.FDCWD,
        Test.base_dir ++ "/" ++ Test.file_name,
        42,
        43,
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    const stat = try fstat(file.handle);
    try testing.expectEqual(42, stat.st_uid);
    try testing.expectEqual(43, stat.st_gid);
}

test "fchownat on a non-existent file fails with ENOENT" {
    const ret = linux.fchownat(
        linux.AT.FDCWD,
        Test.base_dir ++ "/no-such-file",
        0,
        0,
        0,
    );
    try testing.expectEqual(.NOENT, linux.errno(ret));
}

test "fchownat with an unopened dirfd fails with EBADF" {
    const ret = linux.fchownat(999, "somefile", 0, 0, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "fchownat with a negative dirfd that is not AT_FDCWD fails with EBADF" {
    const ret = linux.fchownat(-2, "somefile", 0, 0, 0);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "fchownat with a regular-file fd as dirfd fails with ENOTDIR" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const ret = linux.fchownat(@intCast(fd), "somefile", 0, 0, 0);
    try testing.expectEqual(.NOTDIR, linux.errno(ret));
}

test "fchownat resolves relative to a directory fd" {
    const init = utest.getInit();

    const dir = try std.Io.Dir.openDirAbsolute(
        init.io,
        "/bin",
        .{},
    );
    defer dir.close(init.io);

    const ret = linux.fchownat(@intCast(dir.handle), "utest", 42, 43, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

// =============================================================
// chown / lchown

test "syscall: chown" {
    const init = utest.getInit();
    var t = Test.init();

    const file = try t.createFile();
    defer t.deleteFile();
    defer file.close(init.io);

    const ret = linux.chown(Test.base_dir ++ "/" ++ Test.file_name, 42, 43);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    const stat = try fstat(file.handle);
    try testing.expectEqual(42, stat.st_uid);
    try testing.expectEqual(43, stat.st_gid);
}

test "chown on a non-existent file fails with ENOENT" {
    const ret = linux.chown(Test.base_dir ++ "/no-such-file", 0, 0);
    try testing.expectEqual(.NOENT, linux.errno(ret));
}

test "syscall: lchown" {
    const init = utest.getInit();
    var t = Test.init();

    const file = try t.createFile();
    defer t.deleteFile();
    defer file.close(init.io);

    const ret = linux.lchown(Test.base_dir ++ "/" ++ Test.file_name, 42, 43);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    const stat = try fstat(file.handle);
    try testing.expectEqual(42, stat.st_uid);
    try testing.expectEqual(43, stat.st_gid);
}

test "lchown on a non-existent file fails with ENOENT" {
    const ret = linux.lchown(Test.base_dir ++ "/no-such-file", 0, 0);
    try testing.expectEqual(.NOENT, linux.errno(ret));
}

// =============================================================
// Helpers

/// Fetch the stat information of the given fd.
fn fstat(fd: std.Io.File.Handle) !Stat {
    var statbuf: [4096]u8 align(8) = undefined;
    const ret = std.os.linux.syscall2(
        .fstat,
        @intCast(fd),
        @intFromPtr(&statbuf),
    );
    if (linux.errno(ret) != .SUCCESS) return error.FstatFailed;

    return @as(*const Stat, @ptrCast(&statbuf)).*;
}

const Stat = switch (builtin.cpu.arch) {
    .aarch64 => extern struct {
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
        /// Padding.
        __pad: u64 = 0,
        /// Total size in bytes.
        st_size: i64,
        /// Block size for filesystem I/O.
        st_blksize: i32,
        /// Padding.
        __pad2: i32 = 0,
        /// Number of 512B blocks allocated.
        st_blocks: i64,
        /// Time of last access.
        st_atime: i64 = 0,
        /// Nanoseconds of last access.
        st_atime_nsec: i64 = 0,
        /// Time of last modification.
        st_mtime: i64 = 0,
        /// Nanoseconds of last modification.
        st_mtime_nsec: i64 = 0,
        /// Time of last status change.
        st_ctime: i64 = 0,
        /// Nanoseconds of last status change.
        st_ctime_nsec: i64 = 0,
        /// Padding.
        __unused: [2]u32 = @splat(0),
    },
    .x86_64 => extern struct {
        /// Device ID.
        st_dev: u64,
        /// Inode number.
        st_ino: u64,
        /// Number of hard links.
        st_nlink: u64,
        /// File mode.
        st_mode: u32,
        /// User ID of owner.
        st_uid: u32,
        /// Group ID of owner.
        st_gid: u32,
        /// Reserved.
        __pad0: u32 = 0,
        /// Device ID (if special file).
        st_rdev: u64,
        /// Total size, in bytes.
        st_size: i64,
        /// Block size for filesystem I/O.
        st_blksize: i64,
        /// Number of 512B blocks allocated.
        st_blocks: i64,
        /// Time of last access.
        st_atime: i64 = 0,
        /// Nanoseconds of last access.
        st_atime_nsec: i64 = 0,
        /// Time of last modification.
        st_mtime: i64 = 0,
        /// Nanoseconds of last modification.
        st_mtime_nsec: i64 = 0,
        /// Time of last status change.
        st_ctime: i64 = 0,
        /// Nanoseconds of last status change.
        st_ctime_nsec: i64 = 0,
        /// Padding.
        __unused: [3]i64 = @splat(0),
    },
    else => extern struct {},
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
const Test = utest.fs.Test;
