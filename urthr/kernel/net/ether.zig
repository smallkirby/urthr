//! Ethernet protocol implementation.

/// MAC Address type.
pub const MacAddr = extern struct {
    /// Length in bytes of MAC address.
    pub const length = 6;

    /// Internal byte array representation.
    value: [length]u8,

    /// Broadcast MAC address.
    pub const broadcast = MacAddr{
        .value = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF },
    };

    /// Empty invalid MAC address.
    pub const empty = MacAddr{
        .value = [_]u8{ 0, 0, 0, 0, 0, 0 },
    };
};

/// Ethernet frame header.
///
/// Assuming no preamble and FCS.
const EtherHeader = extern struct {
    /// Destination MAC address.
    dest: MacAddr,
    /// Source MAC address.
    src: MacAddr,
    /// EtherType.
    type: EtherType,
};

/// Ethernet frame EtherType.
const EtherType = enum(u16) {
    /// IPv4
    ip = 0x0800,
    /// ARP
    arp = 0x0806,
};

/// Input Ethernet frame data.
pub fn inputFrame(dev: *net.Device, data: []const u8) void {
    const header: *align(1) const EtherHeader = @ptrCast(data.ptr);

    const is_broadcast = std.mem.eql(u8, MacAddr.broadcast.value[0..], header.dest.value[0..]);
    const is_bound_me = std.mem.eql(u8, dev.addr[0..MacAddr.length], header.dest.value[0..]);
    if (!is_broadcast and !is_bound_me) {
        return;
    }

    const payload = data[@sizeOf(EtherHeader)..];
    net.handleInput(dev, @enumFromInt(@intFromEnum(header.type)), payload) catch {};
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.ether);
const Allocator = std.mem.Allocator;
const common = @import("common");
const bits = common.bits;
const util = common.util;
const urd = @import("urthr");
const net = urd.net;
const Interface = net.Interface;
