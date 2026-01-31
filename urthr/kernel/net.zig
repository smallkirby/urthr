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

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const urd = @import("urthr");
