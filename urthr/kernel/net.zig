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
} || std.fmt.BufPrintError;

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
        pub fn read(self: *const Self, comptime field: Fields) @FieldType(T, @tagName(field)) {
            const name = @tagName(field);
            const U = @FieldType(T, name);
            const bitoffset = @bitOffsetOf(T, name);
            const offset = @offsetOf(T, name);
            const bitsize = @bitSizeOf(U);

            if (bitsize % 8 == 0 and bitoffset % 8 == 0) {
                const up = @intFromPtr(self.p) + offset;
                const value: *const U = @ptrFromInt(up);
                return bits.fromBigEndian(value.*);
            } else {
                @compileError("Unaligned field access is not supported");
            }
        }
    };
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const bits = common.bits;
const urd = @import("urthr");
