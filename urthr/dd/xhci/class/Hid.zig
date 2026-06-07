//! HID class driver.
//!
//! Implements `class.Driver` interface.

const Self = @This();

/// USB interface.
iface: *const Device.Interface,

const vtable = Driver.VTable{
    .name = name,
    .onTransferEvent = onTransferEvent,
};

/// Initialize HID class driver.
pub fn init(iface: *const Device.Interface) Error!Driver {
    const self = try mem.bin.create(Self);
    errdefer mem.bin.destroy(self);
    self.* = .{
        .iface = iface,
    };

    return .{
        .ptr = self,
        .vtable = vtable,
    };
}

fn name() []const u8 {
    return "HID";
}

fn onTransferEvent(_: *anyopaque, _: *const trbs.TransferEventTrb, _: *Endpoint) Error!void {}

// =============================================================
// Imports
// =============================================================

const urd = @import("urthr");
const mem = urd.mem;

const Xhc = @import("../Xhc.zig");
const Error = Xhc.Error;
const Device = @import("../Device.zig");
const Endpoint = Device.Endpoint;
const trbs = @import("../trb.zig");
const class = @import("../class.zig");
const Driver = class.Driver;
