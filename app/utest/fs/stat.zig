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
    const stat: *const Stat = @ptrCast(@alignCast(&statbuf));
    try testing.expectEqual(0, stat.st_uid);
    try testing.expectEqual(0, stat.st_gid);
    try testing.expectEqual(512, stat.st_blksize);
    try testing.expectEqual(content.len, @as(usize, @intCast(stat.st_size)));
    try testing.expect(0 != stat.st_ino);
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
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
const Test = utest.fs.Test;
