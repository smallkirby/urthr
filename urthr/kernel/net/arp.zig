//! ARP protocol implementation.

pub const vtable = net.Protocol.Vtable{
    .input = inputImpl,
};

/// ARP header common part.
const GenericHeader = extern struct {
    /// Hardware address type.
    haddr_type: HaddrType,
    /// Protocol address type.
    paddr_type: PaddrType,
    /// Hardware address length in bytes.
    haddr_len: u8,
    /// Protocol address length in bytes.
    paddr_len: u8,
    /// Operation code.
    op: Op,
};

/// ARP header for MAC and IP address, following generic header.
const AddrInfoMacIp = extern struct {
    /// Sender hardware address.
    sha: ether.MacAddr align(1),
    /// Sender protocol address.
    spa: net.ip.IpAddr align(1),
    /// Target hardware address.
    tha: ether.MacAddr align(1),
    /// Target protocol address.
    tpa: net.ip.IpAddr align(1),
};

const HaddrType = enum(u16) {
    /// Ethernet.
    ether = 0x0001,
};

const PaddrType = enum(u16) {
    /// IPv4.
    ip = 0x0800,
};

const Op = enum(u16) {
    /// ARP request.
    request = 0x0001,
    /// ARP reply.
    reply = 0x0002,
};

pub fn inputImpl(_: *const net.Device, data: []const u8) net.Error!void {
    if (data.len < @sizeOf(GenericHeader)) {
        return net.Error.InvalidPacket;
    }

    const io_common = net.WireReader(GenericHeader).new(data);
    const haddr_type = io_common.read(.haddr_type);
    const paddr_type = io_common.read(.paddr_type);
    const op = io_common.read(.op);

    if (haddr_type != .ether or paddr_type != .ip) {
        // Unsupported address type. Ignore.
        return;
    }
    if (op != .request) {
        // Unsupported operation. Ignore.
        return;
    }

    if (data.len < @sizeOf(GenericHeader) + @sizeOf(AddrInfoMacIp)) {
        return net.Error.InvalidPacket;
    }
    const msgp: *align(1) const AddrInfoMacIp = @ptrCast(data[@sizeOf(GenericHeader)..].ptr);

    // Debug print the ARP packet.
    log.debug("ARP packet: haddr_type={}, paddr_type={}, op={}", .{
        haddr_type,
        paddr_type,
        op,
    });
    log.debug("  Source: {f} , {f}", .{ msgp.sha, msgp.spa });
    log.debug("  Target: {f} , {f}", .{ msgp.tha, msgp.tpa });

    // TODO: implement ARP reply.
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.arp);
const common = @import("common");
const urd = @import("urthr");
const net = urd.net;
const ether = @import("ether.zig");
