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

    _,
};

const PaddrType = enum(u16) {
    /// IPv4.
    ip = 0x0800,

    _,
};

const Op = enum(u16) {
    /// ARP request.
    request = 0x0001,
    /// ARP reply.
    reply = 0x0002,

    _,
};

fn inputImpl(dev: *net.Device, data: []const u8) net.Error!void {
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
    const io_addr = net.WireReader(AddrInfoMacIp).new(data[@sizeOf(GenericHeader)..]);

    // Debug print the ARP packet.
    log.debug("ARP packet: haddr_type={}, paddr_type={}, op={}", .{
        haddr_type,
        paddr_type,
        op,
    });
    log.debug("  Source: {f} , {f}", .{ io_addr.read(.sha), io_addr.read(.spa) });
    log.debug("  Target: {f} , {f}", .{ io_addr.read(.tha), io_addr.read(.tpa) });

    var nbuf = try NetBuffer.init(
        @sizeOf(GenericHeader) + @sizeOf(AddrInfoMacIp),
        urd.mem.getGeneralAllocator(),
    );
    defer nbuf.deinit();

    // Construct common header.
    const ghdr = try nbuf.append(@sizeOf(GenericHeader));
    const gio = net.WireWriter(GenericHeader).new(ghdr);
    gio.write(.haddr_type, .ether);
    gio.write(.paddr_type, .ip);
    gio.write(.haddr_len, @sizeOf(ether.MacAddr));
    gio.write(.paddr_len, @sizeOf(net.ip.IpAddr));
    gio.write(.op, .reply);

    // Construct address info.
    const shdr = try nbuf.append(@sizeOf(AddrInfoMacIp));
    const sio = net.WireWriter(AddrInfoMacIp).new(shdr);
    sio.write(.sha, io_addr.read(.tha));
    sio.write(.spa, io_addr.read(.tpa));
    sio.write(.tha, io_addr.read(.sha));
    sio.write(.tpa, io_addr.read(.spa));

    // Transmit the ARP reply.
    try dev.output(&io_addr.read(.sha).value, .arp, &nbuf);
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
const NetBuffer = @import("NetBuffer.zig");
