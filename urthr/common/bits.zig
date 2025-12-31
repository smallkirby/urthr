/// Concatnate two values and returns new value with twice the bit width.
///
/// - `T` : Type of the output value.
/// - `a` : The first value. Becomes the upper half of the output.
/// - `b` : The second value. Must be the same type as `a`. Becomes the lower half of the output.
pub inline fn concat(T: type, a: anytype, b: @TypeOf(a)) T {
    const U = @TypeOf(a);
    const width_T = @typeInfo(T).int.bits;
    const width_U = switch (@typeInfo(U)) {
        .int => |t| t.bits,
        .comptime_int => width_T / 2,
        else => @compileError("concat: invalid type"),
    };
    if (width_T != width_U * 2) @compileError("concat: invalid type");
    return (@as(T, a) << width_U) | @as(T, b);
}

/// Concatnate arbitrary number of integers in the order of the arguments.
///
/// Numbers MUST NOT be comptime_int.
/// The width MUST be explicitly specified for each value.
///
/// - `T`   : Type of the output value.
/// - `args`: Arbitrary number of values to concatnate.
pub fn concatMany(T: type, args: anytype) T {
    const fields = std.meta.fields(@TypeOf(args));

    // Check if the total width of the args is equal to the output type.
    comptime {
        switch (@typeInfo(@TypeOf(args))) {
            .@"struct" => {},
            else => @compileError("concatMany: invalid type"),
        }

        var width = 0;
        for (fields) |field| {
            width += switch (@typeInfo(field.type)) {
                .int => |t| t.bits,
                else => @compileError("concatMany: invalid type of entry"),
            };
        }
        if (width != @typeInfo(T).int.bits) @compileError("concatMany: total width mismatch");
    }

    // Calculate the result.
    comptime var cur_width = 0;
    var result: T = 0;
    comptime var index = fields.len;
    inline while (index > 0) : (index -= 1) {
        const field = fields[index - 1];
        const val = @field(args, field.name);
        const val_width = switch (@typeInfo(field.type)) {
            .int => |t| t.bits,
            else => @compileError("concatMany: invalid type of entry"),
        };
        result |= @as(T, val) << cur_width;
        cur_width += val_width;
    }

    return result;
}

/// Concatnate two values and returns new value of type `T`.
///
/// - `T` : Type of the output value.
/// - `a` : The first value. Becomes the upper part of the output.
/// - `b` : The second value.
pub inline fn concatAny(T: type, a: anytype, b: @TypeOf(a)) T {
    const U = @TypeOf(b);
    const width_U = @typeInfo(U).int.bits;

    return (@as(T, a) << width_U) | @as(T, b);
}

// =============================================================
// Tests
// =============================================================

const testing = std.testing;

test "concat" {
    try testing.expectEqual(0b10, concat(u2, @as(u1, 1), @as(u1, 0)));
    try testing.expectEqual(0x1234, concat(u16, 0x12, 0x34));
}

test "concatMany" {
    try testing.expectEqual(0b1_1_0, concatMany(u3, .{
        @as(u1, 1),
        @as(u1, 1),
        @as(u1, 0),
    }));
    try testing.expectEqual(0x1111_2222_3333_4444_5555_6666_7777_8888, concatMany(u128, .{
        @as(u32, 0x1111_2222),
        @as(u64, 0x3333_4444_5555_6666),
        @as(u32, 0x7777_8888),
    }));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
