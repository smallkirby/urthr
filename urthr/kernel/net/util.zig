//! Utilities for network protocol stack.

/// Calculate the one's complement checksum of the given bytes.
///
/// The argument is expected to be in network byte order.
/// The return value is in native byte order.
pub fn calcChecksum(data: []const u8) u16 {
    return calcChecksumFrom(data, 0);
}

/// Calculate the one's complement checksum of the given bytes.
///
/// This function starts with the given initial value.
///
/// The argument is expected to be in network byte order.
/// The return value is in native byte order.
pub fn calcChecksumFrom(data: []const u8, initial: u16) u16 {
    var sum: u32 = initial;
    var i: usize = 0;

    while (i + 1 < data.len) : (i += 2) {
        sum += @as(u32, bits.fromBigEndian(std.mem.bytesToValue(u16, data[i .. i + 2])));
    }

    if (i < data.len) {
        sum += @as(u32, data[i]) << 8;
    }

    while ((sum >> 16) != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return ~@as(u16, @intCast(sum));
}

/// Get a reader that handles reading data represented in network byte order.
pub fn WireReader(T: type) type {
    return struct {
        const Self = @This();

        /// Pointer to the backing data.
        p: *align(1) const T,

        /// Fields enum type.
        const Fields = std.meta.FieldEnum(T);

        /// Create a new reader for the given object.
        pub fn new(obj: anytype) Self {
            const ptr: *align(1) const T = switch (@typeInfo(@TypeOf(obj))) {
                .pointer => |pointer| switch (pointer.size) {
                    .one, .many, .c => @ptrCast(@alignCast(obj)),
                    .slice => @ptrCast(@alignCast(obj.ptr)),
                },
                else => @compileError("Invalid type for WireReader"),
            };

            return Self{
                .p = ptr,
            };
        }

        /// Read the value of the given field.
        ///
        /// If the field is an extern struct, it is returned as-is.
        /// Otherwise, it is converted from big-endian to native endian.
        pub fn read(self: *const Self, comptime field: Fields) @FieldType(T, @tagName(field)) {
            const name = @tagName(field);
            const U = @FieldType(T, name);
            const bitoffset = @bitOffsetOf(T, name);
            const offset = @offsetOf(T, name);
            const bitsize = @bitSizeOf(U);

            if (bitsize % 8 != 0 or bitoffset % 8 != 0) {
                @compileError("Unsupported field alignment for WireReader");
            }

            const up = @intFromPtr(self.p) + offset;
            const value: *align(1) const U = @ptrFromInt(up);

            return switch (@typeInfo(U)) {
                .@"struct" => |s| if (s.layout == .@"extern")
                    value.*
                else
                    bits.fromBigEndian(value.*),
                else => bits.fromBigEndian(value.*),
            };
        }
    };
}

/// Get a writer that handles writing data in network byte order.
pub fn WireWriter(T: type) type {
    return struct {
        const Self = @This();

        /// Pointer to the backing data.
        p: *T,

        /// Fields enum type.
        const Fields = std.meta.FieldEnum(T);

        /// Create a new writer for the given object.
        pub fn new(obj: anytype) Self {
            const ptr: *T = switch (@typeInfo(@TypeOf(obj))) {
                .pointer => |pointer| switch (pointer.size) {
                    .one, .many, .c => @ptrCast(@alignCast(obj)),
                    .slice => @ptrCast(@alignCast(obj.ptr)),
                },
                else => @compileError("Invalid type for WireWriter"),
            };

            return Self{
                .p = ptr,
            };
        }

        /// Write a value to the given field.
        ///
        /// If the field is an extern struct, it is written as-is.
        /// Otherwise, it is converted from native endian to big-endian.
        pub fn write(self: *const Self, comptime field: Fields, value: @FieldType(T, @tagName(field))) void {
            const name = @tagName(field);
            const U = @FieldType(T, name);
            const bitoffset = @bitOffsetOf(T, name);
            const offset = @offsetOf(T, name);
            const bitsize = @bitSizeOf(U);

            if (bitsize % 8 != 0 or bitoffset % 8 != 0) {
                @compileError("Unsupported field alignment for WireWriter");
            }

            const up = @intFromPtr(self.p) + offset;
            const dest: *align(1) U = @ptrFromInt(up);

            dest.* = switch (@typeInfo(U)) {
                .@"struct" => |s| if (s.layout == .@"extern")
                    value
                else
                    bits.toBigEndian(value),
                else => bits.toBigEndian(value),
            };
        }

        /// Write a value to the given field without byte order conversion.
        pub fn writeRaw(self: *const Self, comptime field: Fields, value: @FieldType(T, @tagName(field))) void {
            const name = @tagName(field);
            const offset = @offsetOf(T, name);
            const dest = @intFromPtr(self.p) + offset;

            std.mem.writeInt(
                @TypeOf(value),
                @as([*]u8, @ptrFromInt(dest))[0..@sizeOf(@TypeOf(value))],
                value,
                builtin.cpu.arch.endian(),
            );
        }
    };
}

/// Convert the given value in network endian to native endian.
pub fn fromNetEndian(value: anytype) @TypeOf(value) {
    return bits.fromBigEndian(value);
}

/// Convert the given value from native endian to network endian.
pub fn toNetEndian(value: anytype) @TypeOf(value) {
    return bits.toBigEndian(value);
}

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const std = @import("std");
const common = @import("common");
const bits = common.bits;
