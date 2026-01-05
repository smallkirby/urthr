/// Round up the value to the given alignment.
///
/// If the type of `value` is a comptime integer, it's regarded as `usize`.
pub inline fn roundup(value: anytype, alignment: @TypeOf(value)) @TypeOf(value) {
    const T = if (@typeInfo(@TypeOf(value)) == .comptime_int) usize else @TypeOf(value);
    return (value + alignment - 1) & ~@as(T, alignment - 1);
}

/// Round down the value to the given alignment.
///
/// If the type of `value` is a comptime integer, it's regarded as `usize`.
pub inline fn rounddown(value: anytype, alignment: @TypeOf(value)) @TypeOf(value) {
    const T = if (@typeInfo(@TypeOf(value)) == .comptime_int) usize else @TypeOf(value);
    return value & ~@as(T, alignment - 1);
}

/// Check if the given value is aligned to the given alignment.
pub fn isAligned(value: usize, alignment: usize) bool {
    return (value % alignment) == 0;
}

/// Print a hex dump of the given memory region.
pub fn hexdump(addr: usize, len: usize, logger: anytype) void {
    const bytes: [*]const u8 = @ptrFromInt(addr);
    const per_line = 16;

    if (len % per_line != 0) {
        @panic("hexdump: length must be multiple of 16");
    }

    var i: usize = 0;
    while (i < len) : (i += 16) {
        logger(
            "{X} | {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2}",
            .{ addr + i, bytes[i + 0], bytes[i + 1], bytes[i + 2], bytes[i + 3], bytes[i + 4], bytes[i + 5], bytes[i + 6], bytes[i + 7], bytes[i + 8], bytes[i + 9], bytes[i + 10], bytes[i + 11], bytes[i + 12], bytes[i + 13], bytes[i + 14], bytes[i + 15] },
        );
    }
}

// =============================================================
// Tests
// =============================================================

const testing = std.testing;

test roundup {
    try testing.expectEqual(0, roundup(0, 4));
    try testing.expectEqual(4, roundup(1, 4));
    try testing.expectEqual(4, roundup(2, 4));
    try testing.expectEqual(4, roundup(3, 4));
    try testing.expectEqual(4, roundup(4, 4));
    try testing.expectEqual(8, roundup(5, 4));
    try testing.expectEqual(0x2000, roundup(0x1120, 0x1000));
    try testing.expectEqual(0x2000, roundup(0x1FFF, 0x1000));
}

test rounddown {
    try testing.expectEqual(0, rounddown(0, 4));
    try testing.expectEqual(0, rounddown(1, 4));
    try testing.expectEqual(0, rounddown(2, 4));
    try testing.expectEqual(0, rounddown(3, 4));
    try testing.expectEqual(4, rounddown(4, 4));
    try testing.expectEqual(4, rounddown(5, 4));
    try testing.expectEqual(0x1000, rounddown(0x1120, 0x1000));
    try testing.expectEqual(0x1000, rounddown(0x1FFF, 0x1000));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
