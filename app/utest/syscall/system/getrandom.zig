test "syscall: getrandom" {
    var buf = std.mem.zeroes([32]u8);
    const n = try getRandom(&buf, 0);
    try testing.expectEqual(buf.len, n);
    try testing.expect(!std.mem.allEqual(u8, &buf, 0));
}

test "with zero length returns zero" {
    var buf = std.mem.zeroes([8]u8);
    const n = try getRandom(buf[0..0], 0);
    try testing.expectEqual(@as(usize, 0), n);
}

test "returns different data across calls" {
    var buf1 = std.mem.zeroes([32]u8);
    var buf2 = std.mem.zeroes([32]u8);
    _ = try getRandom(&buf1, 0);
    _ = try getRandom(&buf2, 0);

    try testing.expect(!std.mem.eql(u8, &buf1, &buf2));
}

test "can change random source" {
    var buf1 = std.mem.zeroes([32]u8);
    var buf2 = std.mem.zeroes([32]u8);
    _ = try getRandom(&buf1, grnd_random);
    _ = try getRandom(&buf2, grnd_random);

    try testing.expect(!std.mem.eql(u8, &buf1, &buf2));
}

test "rejects reserved flag bits" {
    var buf = std.mem.zeroes([8]u8);
    const ret = linux.syscall3(
        .getrandom,
        @intFromPtr(&buf),
        buf.len,
        0x8000_0000,
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

// =============================================================
// Helpers
// =============================================================

/// GRND_RANDOM
const grnd_random: usize = 0x0001;

fn getRandom(buf: []u8, flags: usize) !usize {
    const ret = linux.syscall3(
        .getrandom,
        @intFromPtr(buf.ptr),
        buf.len,
        flags,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    return ret;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
