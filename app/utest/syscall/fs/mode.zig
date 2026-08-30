test "umask reduces the permission bits of a newly created file" {
    const orig = getUmask();
    defer _ = umask(orig);
    _ = umask(0o022);

    const path = Test.base_dir ++ "mode1";
    const fd = linux.open(
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true },
        0o666,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));
    defer _ = linux.unlink(path);

    try testing.expectEqual(@as(u16, 0o644), try statMode(path) & 0o777);
}

test "zero umask leaves the requested mode of a newly created file unchanged" {
    const orig = getUmask();
    defer _ = umask(orig);
    _ = umask(0);

    const path = Test.base_dir ++ "mode2";
    const fd = linux.open(
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true },
        0o666,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));
    defer _ = linux.unlink(path);

    try testing.expectEqual(@as(u16, 0o666), try statMode(path) & 0o777);
}

test "umask reduces the permission bits of a newly created directory" {
    const orig = getUmask();
    defer _ = umask(orig);
    _ = umask(0o022);

    const path = Test.base_dir ++ "mode1";
    const ret = linux.mkdirat(linux.AT.FDCWD, path, 0o777);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.rmdir(path);

    try testing.expectEqual(@as(u16, 0o755), try statMode(path) & 0o777);
}

test "fchmodat changes the permission bits" {
    const path = Test.base_dir ++ "mode3";
    const fd = linux.open(
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true },
        0o666,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));
    defer _ = linux.unlink(path);

    const ret = linux.fchmodat(linux.AT.FDCWD, path, 0o600);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    try testing.expectEqual(@as(u16, 0o600), try statMode(path) & 0o777);
}

// =============================================================
// Helpers
// =============================================================

/// Get the permission bits of the file.
fn statMode(path: [:0]const u8) !u16 {
    var statxbuf: linux.Statx align(8) = undefined;
    const ret = linux.statx(
        linux.AT.FDCWD,
        path,
        0,
        linux.STATX.BASIC_STATS,
        &statxbuf,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    return statxbuf.mode;
}

/// Install `mask` and return the mask that was in effect before the call.
fn umask(mask: usize) usize {
    return linux.syscall1(.umask, mask);
}

/// Query the current mask without leaving it altered.
fn getUmask() usize {
    const cur = umask(0o022);
    _ = umask(cur);
    return cur;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
const Test = utest.fs.Test;
