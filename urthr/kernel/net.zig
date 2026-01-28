pub const Device = @import("net/Device.zig");
pub const Loopback = @import("net/Loopback.zig");

/// Registered network device list.
var device_list: Device.DeviceList = .{};

/// Initialize network subsystem.
pub fn init() void {}

/// Register a network device.
pub fn registerDevice(device: *Device) void {
    device_list.append(device);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const urd = @import("urthr");
