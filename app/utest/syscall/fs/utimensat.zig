// =============================================================
// utimensat

test "syscall: utimensat" {
    const ret = linux.utimensat(
        linux.AT.FDCWD,
        utest.myname,
        null,
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

test "utimensat sets the timestamps of a path" {
    const fd = try makeTempFile(filename);
    defer _ = linux.close(fd);
    defer _ = linux.unlink(filename);

    const times = [2]linux.timespec{
        .{ .sec = 12, .nsec = 340 },
        .{ .sec = 56, .nsec = 780 },
    };
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.utimensat(linux.AT.FDCWD, filename, &times, 0),
    ));

    const sx = try statxFd(fd);
    try testing.expectEqual(@as(i64, 12), sx.atime.sec);
    try testing.expectEqual(@as(u32, 340), sx.atime.nsec);
    try testing.expectEqual(@as(i64, 56), sx.mtime.sec);
    try testing.expectEqual(@as(u32, 780), sx.mtime.nsec);
}

test "utimensat honors UTIME_NOW and UTIME_OMIT" {
    const fd = try makeTempFile(filename);
    defer _ = linux.close(fd);
    defer _ = linux.unlink(filename);

    const base = [2]linux.timespec{
        .{ .sec = 100, .nsec = 0 },
        .{ .sec = 200, .nsec = 0 },
    };
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.utimensat(fd, null, &base, 0),
    ));

    var t0: linux.timespec = undefined;
    _ = utest.time.clockGetTime(utest.time.CLOCK_REALTIME, &t0);

    // atime -> now, mtime -> unchanged.
    const upd = [2]linux.timespec{
        .{ .sec = 0, .nsec = UTIME_NOW },
        .{ .sec = 0, .nsec = UTIME_OMIT },
    };
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.utimensat(fd, null, &upd, 0),
    ));

    var t1: linux.timespec = undefined;
    _ = utest.time.clockGetTime(utest.time.CLOCK_REALTIME, &t1);

    const sx = try statxFd(fd);
    try testing.expect(t0.sec <= sx.atime.sec and sx.atime.sec <= t1.sec);
    try testing.expectEqual(@as(i64, 200), sx.mtime.sec);
}

test "utimensat with an out-of-range tv_nsec fails with EINVAL" {
    const times = [2]linux.timespec{
        .{ .sec = 0, .nsec = 2_000_000_000 },
        .{ .sec = 0, .nsec = 0 },
    };
    try testing.expectEqual(.INVAL, linux.errno(
        linux.utimensat(linux.AT.FDCWD, utest.myname, &times, 0),
    ));
}

test "utimensat on a non-existent file fails with ENOENT" {
    try testing.expectEqual(.NOENT, linux.errno(
        linux.utimensat(linux.AT.FDCWD, Test.base_dir ++ "no-such-file", null, 0),
    ));
}

test "utimensat with an unopened dirfd fails with EBADF" {
    try testing.expectEqual(.BADF, linux.errno(
        linux.utimensat(999, "somefile", null, 0),
    ));
}

test "utimensat with a regular-file fd as dirfd fails with ENOTDIR" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    try testing.expectEqual(.NOTDIR, linux.errno(
        linux.utimensat(@intCast(fd), "somefile", null, 0),
    ));
}

test "utimensat resolves relative to a directory fd" {
    const init = utest.getInit();

    const dir = try std.Io.Dir.openDirAbsolute(
        init.io,
        "/bin",
        .{},
    );
    defer dir.close(init.io);

    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.utimensat(@intCast(dir.handle), "utest", null, 0),
    ));
}

test "futimens updates an open file descriptor" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.utimensat(@intCast(fd), null, null, 0),
    ));
}

test "utimensat leaves a field unchanged for UTIME_OMIT" {
    const fd = try makeTempFile(filename);
    defer _ = linux.close(fd);
    defer _ = linux.unlink(filename);

    const base = [2]linux.timespec{
        .{ .sec = 11, .nsec = 0 },
        .{ .sec = 22, .nsec = 0 },
    };
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.utimensat(fd, null, &base, 0),
    ));

    const upd = [2]linux.timespec{
        .{ .sec = 33, .nsec = 0 },
        .{ .sec = 0, .nsec = UTIME_OMIT },
    };
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.utimensat(fd, null, &upd, 0),
    ));

    const sx = try statxFd(fd);
    try testing.expectEqual(@as(i64, 33), sx.atime.sec);
    try testing.expectEqual(@as(i64, 22), sx.mtime.sec);
}

test "utimensat with null times sets both to the current time" {
    const fd = try makeTempFile(filename);
    defer _ = linux.close(fd);
    defer _ = linux.unlink(filename);

    var t0: linux.timespec = undefined;
    _ = utest.time.clockGetTime(utest.time.CLOCK_REALTIME, &t0);

    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.utimensat(fd, null, null, 0),
    ));

    var t1: linux.timespec = undefined;
    _ = utest.time.clockGetTime(utest.time.CLOCK_REALTIME, &t1);

    const sx = try statxFd(fd);
    try testing.expect(t0.sec <= sx.mtime.sec and sx.mtime.sec <= t1.sec);
    try testing.expect(t0.sec <= sx.atime.sec and sx.atime.sec <= t1.sec);
}

test "write updates the modification time" {
    const fd = try makeTempFile(filename);
    defer _ = linux.close(fd);
    defer _ = linux.unlink(filename);

    const past = [2]linux.timespec{
        .{ .sec = 1, .nsec = 0 },
        .{ .sec = 1, .nsec = 0 },
    };
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.utimensat(fd, null, &past, 0),
    ));

    var t0: linux.timespec = undefined;
    _ = utest.time.clockGetTime(utest.time.CLOCK_REALTIME, &t0);

    const w = linux.write(fd, "x", 1);
    try testing.expectEqual(.SUCCESS, linux.errno(w));

    const sx = try statxFd(fd);
    try testing.expect(t0.sec <= sx.mtime.sec);
}

// =============================================================
// Helpers
// =============================================================

/// Special `tv_nsec` value requesting the current time.
const UTIME_NOW: i64 = (1 << 30) - 1;
/// Special `tv_nsec` value requesting the timestamp to be left unchanged.
const UTIME_OMIT: i64 = (1 << 30) - 2;

/// Test filename.
const filename = Test.base_dir ++ "utime.txt";

/// `statx` an open file descriptor via `AT_EMPTY_PATH`.
fn statxFd(fd: i32) !linux.Statx {
    var sx: linux.Statx align(8) = undefined;
    const ret = linux.statx(
        fd,
        "",
        linux.AT.EMPTY_PATH,
        linux.STATX.BASIC_STATS,
        &sx,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    return sx;
}

/// Create a writable file for a test and return its fd.
fn makeTempFile(path: [*:0]const u8) !i32 {
    const fd = linux.open(path, .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    return @intCast(fd);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
const Test = utest.fs.Test;
