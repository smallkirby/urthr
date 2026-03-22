//! Loopback device.

const Self = @This();

/// Maximum Transmission Unit.
const mtu = std.math.maxInt(u16);

const vtable = Device.Vtable{
    .transmit = transmitImpl,
};

/// Create a new loopback device.
pub fn new(allocator: Allocator) net.Error!*Device {
    const device = try allocator.create(Device);
    errdefer allocator.destroy(device);

    const flags = Device.Flag{
        .up = true,
    };

    device.* = .{
        .ctx = &.{},
        .vtable = vtable,
        .mtu = mtu,
        .flags = flags,
        .dev_type = .loopback,
        .addr = undefined,
        .addr_len = 0,
        .broadcast = undefined,
    };

    return device;
}

/// Transmit the given data to the device.
///
/// The packet is immediately looped back to the input path without any L2 framing.
fn transmitImpl(dev: *Device, prot: Protocol, buf: *NetBuffer) net.Error!void {
    log.debug("Output to loopback: prot={}", .{prot});
    try net.handleInput(dev, prot, buf.data());
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.loopback);
const Allocator = std.mem.Allocator;
const urd = @import("urthr");
const net = urd.net;
const Protocol = net.Protocol;
const NetBuffer = net.NetBuffer;
const Device = @import("Device.zig");
