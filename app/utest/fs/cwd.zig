test "chdir" {
    var oldbuf: [std.fs.max_path_bytes]u8 = undefined;
    var newbuf: [std.fs.max_path_bytes]u8 = undefined;

    const current = try getcwd(&oldbuf);
    defer chdir(current) catch unreachable;

    const target = Test.base_dir ++ "/bin";
    try chdir(target);
    try testing.expectEqualSlices(u8, target, try getcwd(&newbuf));
}

test "chdir to a non-existent path fails with ENOENT" {
    const rc = linux.chdir(Test.base_dir ++ "/no-such-dir");
    try testing.expectEqual(.NOENT, linux.errno(rc));
}

test "chdir to a regular file fails with ENOTDIR" {
    const rc = linux.chdir(utest.myname);
    try testing.expectEqual(.NOTDIR, linux.errno(rc));
}

test "getcwd with a zero-sized buffer fails with EINVAL" {
    var buf: [1]u8 = undefined;
    const rc = linux.getcwd(&buf, 0);
    try testing.expectEqual(.INVAL, linux.errno(rc));
}

test "getcwd with a too-small buffer fails with ERANGE" {
    var buf: [1]u8 = undefined;
    const rc = linux.getcwd(&buf, buf.len);
    try testing.expectEqual(.RANGE, linux.errno(rc));
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
const utest = @import("../utest.zig");
const Test = utest.fs.Test;
