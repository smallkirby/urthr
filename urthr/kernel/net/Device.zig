//! Network device interface.
//!
//! This is the most primitive abstraction of network stack representing physical devices.
//! Logical network interfaces (e.g., IP interface) are associated with the device.
//!
//! Incoming packets to the device should be dispatched to the appropriate protocol handler
//! that can be found in the registered logical interfaces.

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
/// Logical interfaces associated with this device.
netif: Interface.InterfaceList = .{},

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
    open: ?*const fn (device: *Self) net.Error!void = null,
    /// Output the given data to the device.
    output: *const fn (device: *Self, prot: Protocol, data: []const u8) net.Error!void,
};

/// Link up the device.
pub fn open(self: *Self) net.Error!void {
    if (self.vtable.open) |f| {
        try f(self);
    }

    self.flags.up = true;
}

/// Output the given data to the device.
pub fn output(self: *Self, prot: Protocol, data: []const u8) net.Error!void {
    return self.vtable.output(self, prot, data);
}

/// Associate the given network interface with this device.
pub fn appendInterface(self: *Self, netif: *Interface) net.Error!void {
    var cur = self.netif.first;
    while (cur) |c| : (cur = c.list_head.next) {
        if (c.family == netif.family) {
            return net.Error.Duplicated;
        }
    }

    netif.device = self;
    self.netif.append(netif);
}

/// Get the network interface of the given family.
///
/// Returns null if not found.
pub fn findInterface(self: *const Self, family: Interface.Family) ?*Interface {
    var cur = self.netif.first;

    return while (cur) |c| : (cur = c.list_head.next) {
        if (c.family == family) {
            break c;
        }
    } else null;
}

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const urd = @import("urthr");
const net = urd.net;
const Protocol = net.Protocol;
const Interface = @import("Interface.zig");
