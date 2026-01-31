//! Logical network interface.
//!
//! One physical network device may have multiple logical interfaces.

const Self = @This();

/// Type-erased pointer to the interface implementation.
ctx: *anyopaque,
/// Physical network device associated with this logical interface.
device: ?*net.Device = null,
/// Protocol suite family that defines the addressing scheme.
family: Family,

/// List head for linking network interfaces.
list_head: InterfaceList.Head = .{},

/// List type of network interfaces.
pub const InterfaceList = common.typing.InlineDoublyLinkedList(Self, "list_head");

/// Protocol suite family.
///
/// Single device cannot have multiple logical interfaces of the same family.
pub const Family = enum {
    /// IPv4
    ipv4,
    /// IPv6
    ipv6,
};

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const urd = @import("urthr");
const net = urd.net;
