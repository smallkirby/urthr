//! Port-mapped I/O register.

/// Port I/O register.
///
/// `T` is the type of the register.
/// `Width` is the access width for the register (must be `u8`).
pub fn Register(T: type, Width: type) type {
    if (Width != u8) {
        @compileError("pio.Register only supports u8-width registers");
    }
    if (@sizeOf(T) > @sizeOf(Width)) {
        @compileError(fmt.comptimePrint(
            "pio.Register invalid size: {s} ({d} bytes), {s} ({d} bytes)",
            .{ @typeName(T), @sizeOf(T), @typeName(Width), @sizeOf(Width) },
        ));
    }

    return struct {
        const IntT = std.meta.Int(.unsigned, @bitSizeOf(T));

        /// Read from the register at the given I/O port.
        pub fn read(port: u16) T {
            const value = inb(port);
            return switch (@typeInfo(T)) {
                .@"enum" => @enumFromInt(value),
                else => @bitCast(@as(IntT, @truncate(value))),
            };
        }

        /// Write to the register at the given I/O port.
        pub fn write(port: u16, value: anytype) void {
            const nvalue = if (@TypeOf(value) == comptime_int)
                @as(IntT, value)
            else
                value;
            outb(port, @as(IntT, @bitCast(nvalue)));
        }

        /// Read modify write the register at the given I/O port.
        pub fn modify(port: u16, value: anytype) void {
            var now = read(port);
            inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| {
                @field(now, field.name) = @field(value, field.name);
            }
            write(port, now);
        }
    };
}

/// Defines a module consisting of multiple port I/O registers.
///
/// `fields` is a list of registers that belong to this module, given as
/// offsets from the module's base I/O port.
pub fn Module(comptime fields: []const struct { u16, type }) type {
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

        /// Base I/O port of this module.
        base: u16 = 0,

        /// Set the base I/O port of this module.
        pub fn setBase(self: *Self, base: u16) void {
            self.base = base;
        }

        /// Get the register field information.
        fn getRegister(T: type) struct { u16, type } {
            inline for (fields) |field| {
                const offset, const U = field;
                if (U == T) {
                    return .{ offset, Register(T, u8) };
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
        pub fn write(self: Self, T: type, value: T) void {
            const offset, const MT = getRegister(T);
            MT.write(self.base + offset, value);
        }

        /// Write to the specified field with any type.
        pub fn writei(self: Self, T: type, value: anytype) void {
            const offset, const MT = getRegister(T);
            MT.write(self.base + offset, value);
        }

        /// Write to the specified field.
        ///
        /// The value must be a partial struct of the register type.
        /// The unspecified fields are initialized with zero values.
        pub fn writez(self: Self, T: type, value: anytype) void {
            const offset, const MT = getRegister(T);
            MT.write(self.base + offset, std.mem.zeroInit(T, value));
        }

        /// Modify the specified field.
        pub fn modify(self: Self, T: type, value: anytype) void {
            const offset, const MT = getRegister(T);
            MT.modify(self.base + offset, value);
        }
    };
}

// =============================================================
// Internals
// =============================================================

/// Port I/O operations.
const pio = switch (builtin.cpu.arch) {
    .x86_64 => struct {
        /// Read a single byte from the given I/O port.
        fn inb(port: u16) u8 {
            return asm volatile ("inb %[port], %[ret]"
                : [ret] "={al}" (-> u8),
                : [port] "N{dx}" (port),
            );
        }

        /// Write a single byte to the given I/O port.
        fn outb(port: u16, value: u8) void {
            asm volatile ("outb %[value], %[port]"
                :
                : [value] "{al}" (value),
                  [port] "N{dx}" (port),
            );
        }
    },
    else => @compileError("Port I/O is not supported on this architecture"),
};

const inb = pio.inb;
const outb = pio.outb;

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const std = @import("std");
const fmt = std.fmt;
