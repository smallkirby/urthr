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
/// Device-specific address.
addr: [max_addr_len]u8,
/// Length of the valid address in `addr`.
addr_len: u8,
/// Network device type.
dev_type: Type,
/// Logical interfaces associated with this device.
netif: Interface.InterfaceList = .{},
/// Interrupt vector number for the device.
irq: ?u32 = null,

/// List head for linking network devices.
list_head: DeviceList.Head = .{},

/// Maximum length of the device address.
pub const max_addr_len = 32;

/// List type of network devices.
pub const DeviceList = common.typing.InlineDoublyLinkedList(Self, "list_head");

/// Flags of the network device.
pub const Flag = struct {
    /// The device is up and running.
    up: bool = false,
};

/// Network device type.
pub const Type = enum {
    /// Ethernet device.
    ether,
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
    /// Poll the device for an incoming packet.
    ///
    /// Fills the given buffer with the received packet data and returns the subslice
    /// containing the packet. Returns `null` if no packet is available.
    poll: ?*const fn (device: *Self, buf: []u8) net.Error!?[]const u8 = null,
    /// Process an incoming L2 frame.
    ///
    /// Each device type sets this to the appropriate L2 handler.
    /// Devices that do not receive frames via the packet queue (e.g. loopback) may leave this null.
    inputFrame: ?*const fn (device: *Self, data: []const u8) void = null,
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

/// Poll the device for an incoming packet.
///
/// Fills the given buffer with the received packet data and returns the subslice containing the packet.
/// Returns `null` if no packet is available.
pub fn poll(self: *Self, buf: []u8) net.Error!?[]const u8 {
    return if (self.vtable.poll) |f|
        f(self, buf)
    else
        null;
}

/// Process an incoming L2 frame.
pub fn inputFrame(self: *Self, data: []const u8) void {
    if (self.vtable.inputFrame) |f| {
        f(self, data);
    }
}

/// Return the valid portion of the device address.
pub fn getAddr(self: *const Self) []const u8 {
    return self.addr[0..self.addr_len];
}

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const urd = @import("urthr");
const exception = urd.exception;
const net = urd.net;
const Protocol = net.Protocol;
const Interface = @import("Interface.zig");
