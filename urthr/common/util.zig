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

/// Convert the given pointer to usize value.
pub fn anyaddr(ptr: anytype) usize {
    switch (@typeInfo(@TypeOf(ptr))) {
        .pointer => |p| switch (p.size) {
            .one, .many, .c => return @intFromPtr(ptr),
            .slice => return @intFromPtr(ptr.ptr),
        },
        .int, .comptime_int => return @as(usize, ptr),
        else => @compileError("anyaddr: invalid type"),
    }
}

/// Print a hex dump of the given memory region.
///
/// Buffer is accessed per-byte.
pub fn hexdump(addr: anytype, len: usize, logger: anytype) void {
    if (len == 0) return;

    const start_addr = anyaddr(addr);
    const bytes: [*]const u8 = @ptrFromInt(start_addr);
    const per_line = 16;

    var i: usize = 0;
    while (i < len) : (i += per_line) {
        var hex_buf: [per_line * 3]u8 = undefined;
        var hex_pos: usize = 0;

        for (0..per_line) |j| {
            if (i + j < len) {
                _ = std.fmt.bufPrint(hex_buf[hex_pos..][0..3], "{X:0>2} ", .{bytes[i + j]}) catch unreachable;
            } else {
                @memset(hex_buf[hex_pos..][0..3], ' ');
            }
            hex_pos += 3;
        }

        logger("{X} | {s}", .{ start_addr + i, hex_buf[0..hex_buf.len] });
    }
}

/// Iterator that splits a string into shell-like words.
///
/// Words are basically separated by spaces.
/// A word starting with `'` or `"` extends up to the next matching quote.
/// Quotes are only recognized at the start of a word and no escape sequences are processed.
pub const ShellWordIterator = struct {
    rest: []const u8,

    pub fn init(s: []const u8) ShellWordIterator {
        return .{ .rest = s };
    }

    pub fn next(self: *ShellWordIterator) ?[]const u8 {
        var i: usize = 0;

        // Skip the leading spaces.
        while (i < self.rest.len and self.rest[i] == ' ') i += 1;
        self.rest = self.rest[i..];

        // End of string.
        if (self.rest.len == 0) return null;

        // Parse the next word.
        if (self.rest[0] == '\'' or self.rest[0] == '"') {
            const quote = self.rest[0];
            var end: usize = 1;
            while (end < self.rest.len and self.rest[end] != quote) end += 1;
            const word = self.rest[1..end];
            self.rest = if (end < self.rest.len) self.rest[end + 1 ..] else self.rest[end..];
            return word;
        } else {
            var end: usize = 0;
            while (end < self.rest.len and self.rest[end] != ' ') end += 1;
            const word = self.rest[0..end];
            self.rest = self.rest[end..];
            return word;
        }
    }
};

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

test ShellWordIterator {
    {
        var it = ShellWordIterator.init("hoge 'fuga waiwai' neko");
        try testing.expectEqualStrings("hoge", it.next().?);
        try testing.expectEqualStrings("fuga waiwai", it.next().?);
        try testing.expectEqualStrings("neko", it.next().?);
        try testing.expectEqual(null, it.next());
    }
    {
        var it = ShellWordIterator.init("  a   b  ");
        try testing.expectEqualStrings("a", it.next().?);
        try testing.expectEqualStrings("b", it.next().?);
        try testing.expectEqual(null, it.next());
    }
    {
        var it = ShellWordIterator.init("");
        try testing.expectEqual(null, it.next());
    }
    {
        var it = ShellWordIterator.init("\"double quoted\" 'single quoted'");
        try testing.expectEqualStrings("double quoted", it.next().?);
        try testing.expectEqualStrings("single quoted", it.next().?);
        try testing.expectEqual(null, it.next());
    }
    {
        // Unterminated quote: takes the rest of the string.
        var it = ShellWordIterator.init("'unterminated");
        try testing.expectEqualStrings("unterminated", it.next().?);
        try testing.expectEqual(null, it.next());
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
