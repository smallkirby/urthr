pub const arp = @import("net/arp.zig");
pub const ether = @import("net/ether.zig");
pub const ip = @import("net/ip.zig");

pub const Device = @import("net/Device.zig");
pub const Interface = @import("net/Interface.zig");
pub const Loopback = @import("net/Loopback.zig");

/// Registered network device list.
var device_list: Device.DeviceList = .{};

/// Network error.
pub const Error = error{
    /// Given operation would cause duplication.
    Duplicated,
    /// Memory allocation failed.
    OutOfMemory,
    /// Invalid address.
    InvalidAddress,
    /// Invalid packet data.
    InvalidPacket,
    /// Given data, protocol, or operation is not supported.
    Unsupported,
};

/// Network protocols.
pub const Protocol = enum(u16) {
    /// IPv4
    ip = 0x0800,
    /// ARP
    arp = 0x0806,

    /// All other unrecognized protocols.
    _,

    /// Functions to handle the protocol data.
    pub const Vtable = struct {
        /// Process the incoming data.
        input: *const fn (dev: *const Device, data: []const u8) Error!void,
    };

    /// Get the handler for the given protocol.
    fn getHandler(self: Protocol) ?Protocol.Vtable {
        return switch (self) {
            .ip => @import("net/ip.zig").vtable,
            .arp => @import("net/arp.zig").vtable,
            else => null,
        };
    }
};

/// Initialize network subsystem.
pub fn init() void {}

/// Register a network device.
pub fn registerDevice(device: *Device) void {
    device_list.append(device);
}

/// Handle incoming data to dispatch to the appropriate protocol handler.
pub fn handleInput(dev: *const Device, prot: Protocol, data: []const u8) Error!void {
    if (prot.getHandler()) |handler| {
        // Delegate to the protocol handler
        return handler.input(dev, data);
    } else {
        // Ignore unrecognized protocol
        return;
    }
}

/// Get a reader that handles reading data represented in network byte order.
pub fn WireReader(T: type) type {
    return struct {
        const Self = @This();

        /// Pointer to the backing data.
        p: *const T,

        /// Fields enum type.
        const Fields = std.meta.FieldEnum(T);

        /// Create a new reader for the given object.
        pub fn new(obj: anytype) Self {
            const ptr: *const T = switch (@typeInfo(@TypeOf(obj))) {
                .pointer => |pointer| switch (pointer.size) {
                    .one, .many, .c => @ptrCast(@alignCast(obj)),
                    .slice => @ptrCast(@alignCast(obj.ptr)),
                },
                else => @compileError("Invalid type for WireIo"),
            };

            return Self{
                .p = ptr,
            };
        }

        /// Read the value of the given field.
        ///
        /// If the field is a struct, it is returned as-is.
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
                .@"struct" => value.*,
                else => bits.fromBigEndian(value.*),
            };
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

const std = @import("std");
const common = @import("common");
const bits = common.bits;
const util = common.util;
const urd = @import("urthr");
