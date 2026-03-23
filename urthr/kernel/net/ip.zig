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

    /// Wildcard IP address that matches any address.
    pub const any = IpAddr{
        .value = Inner{ 0, 0, 0, 0 },
    };

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

    /// Check if the two IP addresses are in the same subnet.
    pub fn sameSubnet(self: IpAddr, other: IpAddr, netmask: IpAddr) bool {
        const subnet1 = self.value & netmask.value;
        const subnet2 = other.value & netmask.value;
        return @reduce(.And, subnet1 == subnet2);
    }

    /// Get the subnet address by applying the netmask.
    pub fn subnet(self: IpAddr, netmask: IpAddr) IpAddr {
        return .{ .value = self.value & netmask.value };
    }
};

/// IP specific interface information.
pub const IpInterface = struct {
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
    /// Header Length / Version.
    ihl_version: IhlVersion,
    /// Type of Service.
    tos: u8,
    /// Total Length.
    total_length: u16,
    /// Identification.
    id: u16,
    /// Fragment Offset / Flags.
    fragoff_flags: FragFlags,
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

    const IhlVersion = packed struct(u8) {
        /// Internet Header Length.
        ihl: u4,
        /// Version.
        version: u4,
    };

    const Flags = packed struct(u3) {
        /// Reserved.
        _reserved: u1 = 0,
        /// Don't Fragment.
        df: bool,
        /// More Fragments.
        mf: bool,
    };

    const FragFlags = packed struct(u16) {
        /// Fragment Offset.
        frag_off: u13,
        /// Flags.
        flags: Flags,
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

/// IP header reader.
pub const HeaderReader = net.WireReader(Header);

/// Protocols encapsulated in IP packets.
///
/// See https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml
pub const Protocol = enum(u8) {
    /// IP.
    ip = 0,
    /// ICMP.
    icmp = 1,
    /// TCP.
    tcp = 6,

    /// All other unrecognized protocols.
    _,

    /// Functions to handle the protocol data encapsulated in IP packets.
    pub const Vtable = struct {
        /// Process the incoming data.
        input: *const fn (hdr: HeaderReader, data: []const u8) net.Error!void,
    };

    /// Get the handler for the given protocol.
    fn getHandler(self: Protocol) ?Protocol.Vtable {
        return switch (self) {
            .icmp => @import("icmp.zig").vtable,
            else => null,
        };
    }
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
    const io = net.WireReader(Header).new(data);

    // Check validity of the packet.
    if (data.len < min_packet_size) {
        log.warn("Too short IP packet size: {d}", .{data.len});
        return net.Error.InvalidPacket;
    }

    const version = io.read(.ihl_version).version;
    const ihl = io.read(.ihl_version).ihl;
    if (version != 4) {
        log.warn("Unsupported IP version: {d}", .{version});
        return net.Error.InvalidPacket;
    }

    const hlen = @as(usize, ihl) * 4;
    if (data.len < hlen) {
        log.warn("Invalid IP header length: {d}", .{hlen});
        return net.Error.InvalidPacket;
    }

    if (nutil.calcChecksum(data[0..hlen]) != 0) {
        log.warn("Invalid IP header checksum", .{});
        return net.Error.InvalidPacket;
    }

    // Filter out packets not destined to us.
    const iface = dev.findInterface(.ipv4) orelse {
        log.warn("No IPv4 interface found on the device", .{});
        return net.Error.Unsupported;
    };
    const ip_iface: *const IpInterface = @ptrCast(@alignCast(iface.ctx));
    if (!ip_iface.isDestinedToMe(io.read(.dest_addr))) {
        return;
    }

    // Find the handlre for the encapsulated protocol.
    const protocol = io.read(.protocol);
    if (protocol.getHandler()) |handler| {
        return handler.input(io, data[hlen..io.read(.total_length)]);
    }
}

/// Default Time to Live value.
const default_ttl: u8 = 64;

/// Send an IP packet.
///
/// This function prepends the IP header and transmits the packet
/// through the device whose IPv4 unicast address matches `src`.
pub fn output(src: IpAddr, dest: IpAddr, protocol: Protocol, buf: *NetBuffer) net.Error!void {
    if (src.eql(.broadcast) or dest.eql(.any)) {
        return net.Error.InvalidAddress;
    }

    // Select interface.
    const iface = net.findInterface(isTargetInterface, &src) orelse {
        log.warn("No interface found for the source IP address", .{});
        return net.Error.Unavailable;
    };
    const ip_iface: *const IpInterface = @ptrCast(@alignCast(iface.ctx));
    const device = iface.device orelse {
        log.warn("No device found for the interface", .{});
        return net.Error.Unavailable;
    };

    // Check if the destination address locates in the same subnet.
    if (!ip_iface.unicast.sameSubnet(dest, ip_iface.netmask)) {
        return net.Error.InvalidAddress;
    }

    // Check if the packet size is within the MTU.
    // No fragmentation support for now.
    const packet_len = @sizeOf(Header) + buf.len();
    if (packet_len > device.mtu) {
        return net.Error.InvalidPacket;
    }

    // Fill header fields.
    const hdr = try buf.prepend(@sizeOf(Header));
    const io = net.WireWriter(Header).new(hdr);
    io.write(.ihl_version, .{
        .ihl = @sizeOf(Header) / 4,
        .version = 4,
    });
    io.write(.tos, 0);
    io.write(.total_length, @intCast(packet_len));
    io.write(.id, 0);
    io.write(.fragoff_flags, .{
        .frag_off = 0,
        .flags = .{ ._reserved = 0, .df = false, .mf = false },
    });
    io.write(.ttl, default_ttl);
    io.write(.protocol, protocol);
    io.write(.checksum, 0);
    io.write(.src_addr, src);
    io.write(.dest_addr, dest);

    // Calculate and write the header checksum.
    io.write(.checksum, nutil.calcChecksum(hdr[0..@sizeOf(Header)]));

    // Resolve the destination hardware address.
    const allocator = urd.mem.getGeneralAllocator();
    const hwaddr = try allocator.alloc(u8, device.addr_len);
    defer allocator.free(hwaddr);
    @memset(hwaddr, 0);

    if (dest.eql(ip_iface.broadcast) or dest.eql(.broadcast)) {
        @memcpy(hwaddr, iface.device.?.getBroadcastAddr());
    } else if (iface.device.?.flags.need_arp) {
        try net.arp.resolve(iface, dest, hwaddr);
    }

    // Transmit the packet.
    try device.output(hwaddr, .ip, buf);
}

/// Check if the given interface is the target for receiving the packet.
fn isTargetInterface(interface: *const Interface, ctx: *const anyopaque) bool {
    if (interface.family != .ipv4) {
        return false;
    }

    const addr: *const IpAddr = @ptrCast(@alignCast(ctx));
    const ip_iface: *const IpInterface = @ptrCast(@alignCast(interface.ctx));
    return ip_iface.unicast.eql(addr.*);
}

// =============================================================
// Debug
// =============================================================

/// Print an IP packet data.
fn printPacket(data: []const u8, logger: anytype) void {
    const io = net.WireReader(Header).new(data);
    const ihl = io.read(.ihl_version).ihl;
    const flags = io.read(.fragoff_flags).flags;
    const header_len = @as(usize, ihl) * 4;
    const total_len = @as(usize, io.read(.total_length));
    const payload = data[header_len..total_len];

    logger("Version     : {d}", .{io.read(.ihl_version).version});
    logger("IHL         : {d}", .{io.read(.ihl_version).ihl});
    logger("ToS         : {d}", .{io.read(.tos)});
    logger("Length      : {d}", .{io.read(.total_length)});
    logger("ID          : {d}", .{io.read(.id)});
    logger("Flags       : DF={}, MF={}", .{ flags.df, flags.mf });
    logger("FragOff     : {d}", .{io.read(.fragoff_flags).frag_off});
    logger("TTL         : {d}", .{io.read(.ttl)});
    logger("Protocol    : {d}", .{io.read(.protocol)});
    logger("Checksum    : 0x{X:0>4}", .{io.read(.checksum)});
    logger("Source      : {f}", .{io.read(.src_addr)});
    logger("Dest        : {f}", .{io.read(.dest_addr)});
    logger("Data        :", .{});
    util.hexdump(payload, payload.len, logger);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.ip);
const Allocator = std.mem.Allocator;
const common = @import("common");
const util = common.util;
const urd = @import("urthr");
const net = urd.net;
const Interface = net.Interface;
const nutil = @import("nutil.zig");
const NetBuffer = @import("NetBuffer.zig");
