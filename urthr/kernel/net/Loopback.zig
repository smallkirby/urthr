//! Loopback device.

const Self = @This();

/// Maximum Transmission Unit.
const mtu = std.math.maxInt(u16);

const vtable = Device.Vtable{
    .open = null,
    .output = outputImpl,
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
    };

    return device;
}

/// Output the given data to the device.
fn outputImpl(dev: *Device, prot: Protocol, data: []const u8) net.Error!void {
    log.debug("Output to loopback: prot={}", .{prot});
    try net.handleInput(dev, prot, data);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.loopback);
const Allocator = std.mem.Allocator;
const common = @import("common");
const util = common.util;
const urd = @import("urthr");
const net = urd.net;
const Protocol = net.Protocol;
const Device = @import("Device.zig");
