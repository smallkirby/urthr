//! IP protocol implementation.

pub const vtable = net.Protocol.Vtable{
    .input = inputImpl,
};

/// Minimum packet size.
const min_packet_size = @sizeOf(Header);

/// IP address type.
pub const IpAddr = extern struct {
    /// Integer representation of the IP address in network byte order.
    value: Inner,

    const Inner = @Vector(4, u8);

    /// Length in bytes of IP address.
    pub const length = 4;
    /// Maximum length of string representation of IP address.
    pub const string_length = 15;

    /// Broadcast IP address.
    pub const broadcast = IpAddr{
        .value = Inner{ 0xFF, 0xFF, 0xFF, 0xFF },
    };

    /// Print the IP address into the given buffer.
    fn print(self: IpAddr, buf: []u8) std.fmt.BufPrintError![]u8 {
        const bytes = std.mem.asBytes(&self.value);

        return std.fmt.bufPrint(
            buf,
            "{d}.{d}.{d}.{d}",
            .{ bytes[0], bytes[1], bytes[2], bytes[3] },
        );
    }

    /// Custom formatter.
    pub fn format(self: IpAddr, writer: *std.Io.Writer) !void {
        var buf: [IpAddr.string_length + 1]u8 = undefined;
        const s = self.print(&buf) catch "<invalid>";
        try writer.writeAll(s);
    }

    /// Parse the IP address from the given string.
    pub fn from(s: []const u8) error{InvalidFormat}!IpAddr {
        var count: usize = 0;
        var value: [length]u8 = undefined;

        var iter = std.mem.splitScalar(u8, s, '.');
        while (iter.next()) |part| : (count += 1) {
            if (count >= 4) {
                return error.InvalidFormat;
            }

            const num = std.fmt.parseInt(u8, part, 10) catch {
                return error.InvalidFormat;
            };

            value[count] = num;
        }
        if (count != 4) {
            return error.InvalidFormat;
        }

        return .{ .value = value };
    }

    /// Check equality with another IP address.
    pub fn eql(self: IpAddr, other: IpAddr) bool {
        return std.meta.eql(self.value, other.value);
    }
};

/// IP specific interface information.
const IpInterface = struct {
    /// Unicast IP address.
    unicast: IpAddr,
    /// Broadcast IP address.
    broadcast: IpAddr,
    /// Subnet mask.
    netmask: IpAddr,

    /// Check if the given address is destined to this interface.
    pub fn isDestinedToMe(self: *const IpInterface, addr: IpAddr) bool {
        const unicast = addr.eql(self.unicast);
        const broadcast = addr.eql(.broadcast);
        const subnet_broadcast = addr.eql(self.broadcast);

        return unicast or broadcast or subnet_broadcast;
    }
};

/// IP header.
///
/// This struct provides only the mandatory fields excluding options.
const Header = extern struct {
    /// Header Length (4 bits) / Version (4 bits).
    ihl_version: u8,
    /// Type of Service.
    tos: u8,
    /// Total Length.
    total_length: u16,
    /// Identification.
    id: u16,
    /// Fragment Offset (13 bits) / Flags (3 bits).
    fragoff_flags: u16,
    /// Time to Live.
    ttl: u8,
    /// Protocol.
    protocol: Protocol,
    /// Header Checksum.
    checksum: u16,
    /// Source IP Address.
    src_addr: IpAddr,
    /// Destination IP Address.
    dest_addr: IpAddr,

    const Flags = packed struct(u3) {
        /// Reserved.
        _reserved: u1 = 0,
        /// Don't Fragment.
        df: bool,
        /// More Fragments.
        mf: bool,
    };

    /// Get the packet data following the header.
    pub fn data(self: *const Header) []const u8 {
        const io = net.WireReader(Header).new(self);
        const header_len = @as(usize, io.read(.ihl_version) & 0x0F) * 4;
        const total_len = @as(usize, io.read(.total_length));
        const ptr: [*]const u8 = @ptrCast(self);

        return ptr[header_len..total_len];
    }
};

/// Protocol numbers for IP.
///
/// See https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml
const Protocol = enum(u8) {
    /// IP.
    ip = 0,
    /// ICMP.
    icmp = 1,
    /// TCP.
    tcp = 6,

    /// All other unrecognized protocols.
    _,
};

/// Create a logical interface for IP.
pub fn createInterface(unicast: IpAddr, netmask: IpAddr, allocator: Allocator) net.Error!*net.Interface {
    const interface = try allocator.create(net.Interface);
    errdefer allocator.destroy(interface);

    const ipif = try allocator.create(IpInterface);
    errdefer allocator.destroy(ipif);

    ipif.* = .{
        .unicast = unicast,
        .netmask = netmask,
        .broadcast = .{
            .value = (unicast.value & netmask.value) | ~netmask.value,
        },
    };
    interface.* = .{
        .ctx = @ptrCast(ipif),
        .family = .ipv4,
    };

    return interface;
}

/// Handle incoming IP packet.
fn inputImpl(dev: *const net.Device, data: []const u8) net.Error!void {
    const header: *const Header = @ptrCast(@alignCast(data.ptr));
    const io = net.WireReader(Header).new(data);

    // Check validity of the packet.
    if (data.len < min_packet_size) {
        log.warn("Too short IP packet size: {d}", .{data.len});
        return net.Error.InvalidPacket;
    }

    const version = io.read(.ihl_version) >> 4;
    const ihl = io.read(.ihl_version) & 0x0F;
    if (version != 4) {
        log.warn("Unsupported IP version: {d}", .{version});
        return net.Error.InvalidPacket;
    }

    const hlen = @as(usize, ihl) * 4;
    if (data.len < hlen) {
        log.warn("Invalid IP header length: {d}", .{hlen});
        return net.Error.InvalidPacket;
    }

    if (calcChecksum(data[0..hlen]) != 0) {
        log.warn("Invalid IP header checksum", .{});
        return net.Error.InvalidPacket;
    }

    // Filter out packets not destined to us.
    const iface = dev.findInterface(.ipv4) orelse {
        log.warn("No IPv4 interface found on the device", .{});
        return net.Error.Unsupported;
    };
    const ip_iface: *const IpInterface = @ptrCast(@alignCast(iface.ctx));
    if (!ip_iface.isDestinedToMe(header.dest_addr)) {
        return;
    }

    // TODO: just printing the packet for now.
    printPacket(header, log.debug);
}

/// Calculate the one's complement checksum of the given bytes.
fn calcChecksum(header: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;

    while (i + 1 < header.len) : (i += 2) {
        sum += @as(u32, std.mem.bytesToValue(u16, header[i .. i + 2]));
    }

    if (i < header.len) {
        sum += @as(u32, header[i]);
    }

    while ((sum >> 16) != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return ~@as(u16, @intCast(sum));
}

/// Print an IP packet data.
fn printPacket(header: *const Header, logger: anytype) void {
    const io = net.WireReader(Header).new(header);
    const version = bits.extract(u4, io.read(.ihl_version), 4);
    const ihl = bits.extract(u4, io.read(.ihl_version), 0);
    const flags = bits.extract(Header.Flags, io.read(.fragoff_flags), 13);
    const frag_off = bits.extract(u13, io.read(.fragoff_flags), 0);
    const src = header.src_addr;
    const dest = header.dest_addr;
    const data = header.data();

    logger("Version     : {d}", .{version});
    logger("IHL         : {d}", .{ihl});
    logger("ToS         : {d}", .{io.read(.tos)});
    logger("Length      : {d}", .{io.read(.total_length)});
    logger("ID          : {d}", .{io.read(.id)});
    logger("Flags       : DF={}, MF={}", .{ flags.df, flags.mf });
    logger("FragOff     : {d}", .{frag_off});
    logger("TTL         : {d}", .{io.read(.ttl)});
    logger("Protocol    : {d}", .{io.read(.protocol)});
    logger("Checksum    : 0x{X:0>4}", .{io.read(.checksum)});
    logger("Source      : {f}", .{src});
    logger("Dest        : {f}", .{dest});
    logger("Data        :", .{});
    util.hexdump(data, data.len, logger);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.ip);
const Allocator = std.mem.Allocator;
const common = @import("common");
const bits = common.bits;
const util = common.util;
const urd = @import("urthr");
const net = urd.net;
const Interface = net.Interface;
