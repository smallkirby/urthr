//! Network device interface.

const Self = @This();

/// Type-erased pointer to the device implementation.
ctx: *anyopaque,
/// Vtable of the device implementation.
vtable: Vtable,
/// Maximum transmission unit in bytes.
mtu: u16,
/// Flags of the network device.
flags: Flag,
/// Network device type.
dev_type: Type,

/// List head for linking network devices.
list_head: DeviceList.Head = .{},

/// List type of network devices.
pub const DeviceList = common.typing.InlineDoublyLinkedList(Self, "list_head");

/// Flags of the network device.
pub const Flag = struct {
    /// The device is up and running.
    up: bool = false,
};

/// Network device type.
pub const Type = enum {
    /// Loopback device.
    loopback,
};

/// Functions that network device must implement.
pub const Vtable = struct {
    /// Link up the device.
    ///
    /// If the device is already up, this is a no-op.
    open: ?*const fn (device: *anyopaque) net.Error!void = null,
    /// Output the given data to the device.
    output: *const fn (device: *anyopaque, prot: Protocol, data: []const u8) net.Error!void,
};

/// Link up the device.
pub fn open(self: *Self) net.Error!void {
    if (self.vtable.open) |f| {
        try f(self.ctx);
    }

    self.flags.up = true;
}

/// Output the given data to the device.
pub fn output(self: *Self, prot: Protocol, data: []const u8) net.Error!void {
    return self.vtable.output(self.ctx, prot, data);
}

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const urd = @import("urthr");
const net = urd.net;
const Protocol = net.Protocol;
