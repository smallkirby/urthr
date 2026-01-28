//! Loopback device.

const Self = @This();

/// Maximum Transmission Unit.
const mtu = std.math.maxInt(u16);

const vtable = Device.Vtable{
    .open = null,
    .output = outputImpl,
};

/// Create a new loopback device.
pub fn new(allocator: Allocator) Error!*Device {
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
    };

    return device;
}

/// Output the given data to the device.
///
/// TODO: just printing the data for now.
fn outputImpl(_: *anyopaque, data: []const u8) Error!void {
    util.hexdump(data, data.len, log.debug);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.loopback);
const Allocator = std.mem.Allocator;
const common = @import("common");
const util = common.util;
const Device = @import("Device.zig");
const Error = Device.Error;
