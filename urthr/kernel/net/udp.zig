//! UDP: User Datagram Protocol implementation.

pub const vtable = net.ip.Protocol.Vtable{
    .input = inputImpl,
};

/// Handle an incoming UDP packet.
fn inputImpl(iphdr: net.ip.HeaderReader, data: []const u8) net.Error!void {
    if (data.len < @sizeOf(Header)) {
        log.warn("Too small UDP packet: {d}", .{data.len});
        return net.Error.InvalidPacket;
    }

    var pseudo_data = std.mem.zeroInit(PseudoHeader, .{});
    const pseudo = net.WireWriter(PseudoHeader).new(&pseudo_data);
    const hdr = net.WireReader(Header).new(data);

    // Validate data.
    if (data.len < hdr.read(.length)) {
        log.warn("UDP packet length mismatch: header {d}, actual {d}", .{ hdr.read(.length), data.len });
        return net.Error.InvalidPacket;
    }

    // If the checksum field is non-zero, validate the checksum.
    if (hdr.read(.checksum) != 0) {
        pseudo.write(.src, iphdr.read(.src_addr));
        pseudo.write(.dst, iphdr.read(.dest_addr));
        pseudo.write(.protocol, .udp);
        pseudo.write(.length, hdr.read(.length));

        const pseudo_sum = nutil.calcChecksum(std.mem.asBytes(&pseudo_data));
        if (nutil.calcChecksumFrom(data, ~pseudo_sum) != 0) {
            log.warn("Invalid UDP checksum", .{});
            return net.Error.InvalidPacket;
        }
    }

    print(data, log.debug);
}

// =============================================================
// Data structures
// =============================================================

/// UDP port type.
const Port = u16;

/// UDP header as defined in RFC 768.
const Header = extern struct {
    /// Source port.
    src: Port,
    /// Destination port.
    dst: Port,
    /// Length of the UDP header and payload in bytes.
    length: u16,
    /// Checksum.
    checksum: u16,
};

/// Pseudo header used for checksum calculation.
const PseudoHeader = extern struct {
    /// Source IP address.
    src: IpAddr,
    /// Destination IP address.
    dst: IpAddr,
    /// Always zero.
    zero: u8 = 0,
    /// Protocol number.
    protocol: net.ip.Protocol,
    /// Length of the UDP header and payload in bytes.
    length: u16,
};

// =============================================================
// Debug
// =============================================================

/// debug print the given UDP packet.
fn print(data: []const u8, logger: anytype) void {
    const io = net.WireReader(Header).new(data);
    const len = io.read(.length);
    const inner = data[@sizeOf(Header)..len];

    logger("UDP packet: size={d}", .{data.len});
    logger("  source : {d}", .{io.read(.src)});
    logger("  dest   : {d}", .{io.read(.dst)});
    logger("  length : {d}", .{len});
    logger("  sum    : {X:0>4}", .{io.read(.checksum)});
    common.util.hexdump(inner, inner.len, logger);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.udp);
const common = @import("common");
const urd = @import("urthr");
const net = urd.net;
const IpAddr = net.ip.IpAddr;
const nutil = @import("nutil.zig");
