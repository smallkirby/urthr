/// Memory-mapped I/O register.
///
/// You can read from and write to the register with a correct access width.
///
/// `T` is the type of the register.
/// `W` is the access width for the register.
/// Size of `T` must be less than or equal to size of `W`.
pub fn Register(T: type, Width: type) type {
    if (!std.math.isPowerOfTwo(@bitSizeOf(Width))) {
        @compileError(fmt.comptimePrint(
            "MmioRegister invalid width: {s} ({d} bits)",
            .{ @typeName(Width), @bitSizeOf(Width) },
        ));
    }

    if (@sizeOf(T) > @sizeOf(Width)) {
        @compileError(fmt.comptimePrint(
            "MmioRegister invalid size: {s} ({d} bytes), {s} ({d} bytes)",
            .{ @typeName(T), @sizeOf(T), @typeName(Width), @sizeOf(Width) },
        ));
    }

    return struct {
        const Self = @This();

        const IntW = std.meta.Int(.unsigned, @bitSizeOf(Width));
        const IntT = std.meta.Int(.unsigned, @bitSizeOf(T));

        /// Read from the MMIO register at the given address.
        ///
        /// Caller must ensure that the given `addr` is aligned to `Width`.
        pub fn read(addr: usize) T {
            const ptr: *const volatile Width = @ptrFromInt(addr);
            const value: Width = ptr.*;
            return @bitCast(@as(IntT, @truncate(value)));
        }

        /// Write to the MMIO register at the given address.
        ///
        /// Caller must ensure that the given `addr` is aligned to `Width`.
        pub fn write(addr: usize, value: anytype) void {
            const nvalue = if (@TypeOf(value) == comptime_int)
                @as(IntT, value)
            else
                value;
            const ptr: *volatile Width = @ptrFromInt(addr);
            const w: Width = @as(IntT, @bitCast(nvalue));
            ptr.* = w;
        }

        /// Read modify write the MMIO register at the given address.
        ///
        /// Caller must ensure that the given `addr` is aligned to `Width`.
        pub fn modify(addr: usize, value: anytype) void {
            var now = read(addr);
            inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| {
                @field(now, field.name) = @field(value, field.name);
            }
            write(addr, now);
        }
    };
}

pub const Align = union(enum) {
    /// Automatic alignment based on the register width with check of maximum alignment size.
    natural: type,
    /// Mandatory alignment size in bytes.
    size: type,
};

/// Defines a module consisting of multiple MMIO registers.
///
/// `fields` is a list of MMIO registers that belong to this module.
pub fn Module(Width: Align, comptime fields: []const struct { usize, type }) type {
    comptime {
        for (fields, 0..) |field, i| {
            if (i + 1 == fields.len) break;
            _, const T = field;

            for (fields[i + 1 ..]) |next| {
                _, const NT = next;
                if (T == NT) {
                    @compileError("Duplicate field type in Module: " ++ @typeName(T));
                }
            }
        }
    }

    return struct {
        const Self = @This();

        /// Base address of this register.
        base: usize = 0,

        /// Set the base address of this register.
        pub fn setBase(self: *Self, base: usize) void {
            self.base = base;
        }

        /// Get the required alignment for the register.
        fn getAlignment(T: type) type {
            return switch (Width) {
                .natural => |max| std.meta.Int(.unsigned, @min(@bitSizeOf(T), @bitSizeOf(max))),
                .size => |size| size,
            };
        }

        /// Get the register field information.
        fn getRegister(T: type) struct { usize, type } {
            inline for (fields) |field| {
                const offset, const U = field;
                if (U == T) {
                    return .{ offset, Register(T, getAlignment(T)) };
                }
            }
            @compileError("Register not found in Module: " ++ @typeName(T));
        }

        /// Read the specified field.
        pub fn read(self: Self, T: type) T {
            const offset, const MT = getRegister(T);
            return MT.read(self.base + offset);
        }

        /// Write to the specified field.
        pub fn write(self: Self, T: type, value: anytype) void {
            const offset, const MT = getRegister(T);

            MT.write(self.base + offset, value);
        }

        /// Modify the specified field.
        pub fn modify(self: Self, T: type, value: anytype) void {
            const offset, const MT = getRegister(T);

            MT.modify(self.base + offset, value);
        }
    };
}

// =============================================================
// Tests
// =============================================================

const testing = std.testing;

test Register {
    const A = packed struct {
        a: u16,
        b: u8,
        c: bool,
        d: bool,
    };

    var raw: A align(4) = .{
        .a = 0x1234,
        .b = 0x56,
        .c = true,
        .d = false,
    };
    const addr = @intFromPtr(&raw);
    const R = Register(A, u32);

    // Read
    {
        const v = R.read(addr);
        try testing.expectEqual(raw, v);
    }

    // Write
    {
        const v: A = .{
            .a = 0xABCD,
            .b = 0xEF,
            .c = false,
            .d = true,
        };
        R.write(addr, v);
        try testing.expectEqual(v, raw);
    }

    // Modify
    {
        R.modify(addr, .{
            .a = 0x9876,
            .d = false,
        });
        try testing.expectEqual(A{
            .a = 0x9876,
            .b = 0xEF,
            .c = false,
            .d = false,
        }, raw);
    }
}

test Module {
    const A = packed struct {
        a: u16,
        b: u8,
        c: bool,
        d: bool,
    };
    const B = packed struct {
        x: u16,
        y: bool,
    };
    const M = Module(.{ .size = u32 }, &.{
        .{ 0x00, A },
        .{ 0x08, B },
    });

    var raw: [12]u8 align(8) = undefined;
    const rawa: *A = @ptrFromInt(@intFromPtr(&raw) + 0);
    const rawb: *B = @ptrFromInt(@intFromPtr(&raw) + 8);
    rawa.* = .{
        .a = 0x1111,
        .b = 0x22,
        .c = true,
        .d = false,
    };
    rawb.* = .{
        .x = 0x3333,
        .y = true,
    };

    var module: M = .{};
    module.setBase(@intFromPtr(&raw));

    // Read
    {
        const a = module.read(A);
        try testing.expectEqual(rawa.*, a);

        const b = module.read(B);
        try testing.expectEqual(rawb.*, b);
    }

    // Write
    {
        const a: A = .{
            .a = 0xAAAA,
            .b = 0xBB,
            .c = false,
            .d = true,
        };
        module.write(A, a);
        try testing.expectEqual(a, rawa.*);

        const b: B = .{
            .x = 0xCCCC,
            .y = false,
        };
        module.write(B, b);
        try testing.expectEqual(b, rawb.*);
    }

    // Modify
    {
        module.modify(A, .{
            .a = 0x1234,
            .d = false,
        });
        try testing.expectEqual(A{
            .a = 0x1234,
            .b = 0xBB,
            .c = false,
            .d = false,
        }, rawa.*);

        module.modify(B, .{
            .y = true,
        });
        try testing.expectEqual(B{
            .x = 0xCCCC,
            .y = true,
        }, rawb.*);
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const fmt = std.fmt;
