//! IP protocol implementation.

pub const vtable = net.Protocol.Vtable{
    .input = inputImpl,
};

/// IP address type.
pub const IpAddr = extern struct {
    /// Integer representation of the IP address in network byte order.
    _value: Inner,

    const Inner = @Vector(length, u8);

    /// Length in bytes of IP address.
    pub const length = 4;
    /// Maximum length of string representation of IP address.
    pub const string_length = 15;

    /// Wildcard IP address that matches any address.
    pub const any = IpAddr{
        ._value = Inner{ 0, 0, 0, 0 },
    };

    /// Limited broadcast IP address.
    pub const limited_broadcast = IpAddr{
        ._value = Inner{ 0xFF, 0xFF, 0xFF, 0xFF },
    };

    /// Custom formatter.
    pub fn format(self: IpAddr, writer: *std.Io.Writer) !void {
        var buf: [IpAddr.string_length + 1]u8 = undefined;
        const s = std.fmt.bufPrint(
            &buf,
            "{d}.{d}.{d}.{d}",
            .{ self._value[0], self._value[1], self._value[2], self._value[3] },
        ) catch "<invalid>";

        try writer.writeAll(s);
    }

    /// Create an IP address from the given byte array.
    pub fn from(value: *const [length]u8) IpAddr {
        return IpAddr{ ._value = value.* };
    }

    /// Parse the IP address from the given string.
    pub fn parse(s: []const u8) error{InvalidFormat}!IpAddr {
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

        return .{ ._value = value };
    }

    /// comptime version of `parse()`.
    pub fn comptimeParse(comptime s: []const u8) IpAddr {
        if (comptime std.mem.count(u8, s, ".") + 1 != 4) {
            @compileError("Invalid IP address (wrong number of octets): " ++ s);
        }
        comptime var iter = std.mem.splitScalar(u8, s, '.');
        comptime var count: usize = 0;
        comptime var value: [length]u8 = undefined;
        comptime while (iter.next()) |part| : (count += 1) {
            const num = std.fmt.parseInt(u8, part, 10) catch {
                @compileError("Invalid IP address part: " ++ part);
            };
            value[count] = num;
        };

        return .{ ._value = value };
    }

    /// Get the subnet address by applying the netmask.
    pub fn subnet(self: IpAddr, netmask: IpAddr) IpAddr {
        return .{ ._value = self._value & netmask._value };
    }

    /// Get the directed broadcast address for the given netmask.
    pub fn getDirectedBroadcast(self: IpAddr, netmask: IpAddr) IpAddr {
        return .{ ._value = (self._value & netmask._value) | ~netmask._value };
    }

    /// Check equality with another IP address.
    pub fn eql(self: IpAddr, other: IpAddr) bool {
        return std.meta.eql(self._value, other._value);
    }

    /// Check if this IP address is greater than or equal to another IP address.
    pub fn gte(self: IpAddr, other: IpAddr) bool {
        const lhs = net.util.fromNetEndian(@as(u32, @bitCast(self._value)));
        const rhs = net.util.fromNetEndian(@as(u32, @bitCast(other._value)));
        return lhs >= rhs;
    }
};

/// IP-specific interface information.
pub const Interface = struct {
    const Self = @This();

    /// Common interface information.
    base: net.Interface,

    /// Unicast IP address of the interface.
    unicast: IpAddr,
    /// Broadcast IP address.
    broadcast: IpAddr,
    /// Subnet mask.
    netmask: IpAddr,

    /// Create a logical interface for IP.
    ///
    /// Returned interface is not linked to physical device yet.
    pub fn create(unicast: IpAddr, netmask: IpAddr, allocator: Allocator) net.Error!*net.Interface {
        const ipif = try allocator.create(Interface);
        errdefer allocator.destroy(ipif);

        ipif.* = .{
            .unicast = unicast,
            .netmask = netmask,
            .broadcast = unicast.getDirectedBroadcast(netmask),
            .base = .{ .family = .ipv4 },
        };

        // Register a route for the directly connected subnet of the interface.
        try ipif.addRoute(
            unicast.subnet(netmask),
            netmask,
            .any,
        );

        return &ipif.base;
    }

    /// Check if the given address is destined to this interface.
    pub fn isForMe(self: *const Interface, addr: IpAddr) bool {
        return addr.eql(self.unicast) or addr.eql(.limited_broadcast) or addr.eql(self.broadcast);
    }

    /// Add a routing entry for this interface.
    pub fn addRoute(self: *Interface, network: IpAddr, netmask: IpAddr, gateway: IpAddr) net.Error!void {
        try routeAdd(network, netmask, gateway, &self.base);
    }

    /// Downcast the common interface.
    pub fn downcast(iface: *net.Interface) *Self {
        rtt.expectEqual(.ipv4, iface.family);
        return @fieldParentPtr("base", iface);
    }

    /// Update the interface configuration.
    pub fn update(self: *Interface, unicast: IpAddr, netmask: IpAddr) void {
        self.unicast = unicast;
        self.netmask = netmask;
        self.broadcast = unicast.getDirectedBroadcast(netmask);
    }
};

/// Handle incoming IP packet.
///
/// `dev` is a physical device on which the packet is received.
/// It's not ensured that the packet is destined to this device.
///
/// The packet payload is passed to the appropriate handler based on the protocol field.
fn inputImpl(dev: *const net.Device, data: []const u8) net.Error!void {
    const io = net.util.WireReader(Header).new(data);

    // Check validity of the packet.
    if (data.len < @sizeOf(Header)) {
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

    // Filter out packets not destined to us.
    const iface = dev.findInterface(.ipv4) orelse {
        log.warn("No IPv4 interface found on the device", .{});
        return net.Error.Unsupported;
    };
    const ipif = Interface.downcast(iface);
    if (!ipif.isForMe(io.read(.dest_addr))) {
        return;
    }

    // Validate header checksum.
    if (net.util.calcChecksum(data[0..hlen]) != 0) {
        log.warn("Invalid IP header checksum", .{});
        return net.Error.InvalidPacket;
    }

    // Debug print the packet.
    print(data, trace);

    // Find the handler for the encapsulated protocol.
    const protocol: Protocol = io.read(.protocol);
    if (protocol.getHandler()) |handler| {
        return handler.input(
            io,
            ipif,
            data[hlen..io.read(.total_length)],
        );
    } else {
        log.warn("Unsupported IP protocol: {d}", .{@intFromEnum(protocol)});
        return;
    }
}

/// Default Time to Live value.
const default_ttl: u8 = 64;

/// Send an IP packet.
///
/// This function prepends the IP header and transmits the packet
/// through the device whose IPv4 unicast address matches `src`.
///
/// Owns the given buffer on success.
/// Caller must not access the buffer after calling this function.
pub fn output(src: IpAddr, dest: IpAddr, prot: Protocol, buf: *NetBuffer) net.Error!void {
    // Lookup the route for the destination IP address.
    const route = routeLookup(dest) orelse {
        log.warn("No route found for the destination IP address: {f}", .{dest});
        return net.Error.Unavailable;
    };

    // Select interface.
    const ipif = route.iface;
    const device = ipif.base.device orelse {
        log.warn("No device found for the interface", .{});
        return net.Error.Unavailable;
    };

    if (!src.eql(.any) and !ipif.unicast.eql(src)) {
        log.warn("Source IP address does not match the interface address.", .{});
        log.warn("  source: {f} vs iface: {f}", .{ src, ipif.unicast });
        return net.Error.InvalidAddress;
    }
    const next = if (route.gateway.eql(.any)) dest else route.gateway;

    // Check if the packet size is within the MTU.
    // No fragmentation support for now.
    const packet_len = @sizeOf(Header) + buf.len();
    if (packet_len > device.mtu) {
        return net.Error.InvalidPacket;
    }

    // Fill header fields.
    const hdr = try buf.prepend(@sizeOf(Header));
    const io = net.util.WireWriter(Header).new(hdr);
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
    io.write(.protocol, prot);
    io.write(.checksum, 0);
    io.write(.src_addr, src);
    io.write(.dest_addr, next);

    // Calculate and write the header checksum.
    io.write(.checksum, net.util.calcChecksum(hdr[0..@sizeOf(Header)]));

    // Resolve the destination hardware address.
    const allocator = urd.mem.getGeneralAllocator();
    const hwaddr = try allocator.alloc(u8, device.addr_len);
    defer allocator.free(hwaddr);
    @memset(hwaddr, 0);

    if (next.eql(.limited_broadcast)) {
        @memcpy(hwaddr, device.getBroadcastAddr());
    } else if (device.flags.need_arp) {
        net.arp.resolve(&ipif.base, next, hwaddr) catch |err| switch (err) {
            error.Resolving => return net.arp.cache.enqueuePending(next, device, buf.*),
            else => return err,
        };
    }

    try net.enqueueTx(device, hwaddr, .ipv4, buf.*);
}

/// Update the network configuration of the interface.
pub fn updateConfig(iface: *net.Interface, unicast: IpAddr, netmask: IpAddr) void {
    rtt.expectEqual(.ipv4, iface.family);
    const ipif = Interface.downcast(iface);
    ipif.update(unicast, netmask);
}

// =============================================================
// Routing
// =============================================================

/// A list of registered routes.
var routes: std.array_list.Aligned(Route, null) = .{};

/// Represents a network routing entry that defines how packets should be forwarded.
const Route = struct {
    /// Network address.
    ///
    /// .any indicates a default gateway.
    network: IpAddr,
    /// Subnet mask.
    netmask: IpAddr,
    /// Next-hop IP address.
    ///
    /// .any indicates that the destination is directly connected to the interface.
    gateway: IpAddr,
    /// Interface to send the packet.
    iface: *Interface,
};

/// Add a routing entry.
pub fn routeAdd(network: IpAddr, netmask: IpAddr, gateway: IpAddr, iface: *net.Interface) Allocator.Error!void {
    rtt.expectEqual(.ipv4, iface.family);
    const ipif = Interface.downcast(iface);

    const allocator = urd.mem.getGeneralAllocator();
    const route = try allocator.create(Route);
    errdefer allocator.destroy(route);

    route.* = .{
        .network = network,
        .netmask = netmask,
        .gateway = gateway,
        .iface = ipif,
    };

    try routes.append(allocator, route.*);
}

/// Lookup the routing entry for the given destination IP address.
///
/// If multiple entries match the destination, the one with the longest prefix is selected.
pub fn routeLookup(dest: IpAddr) ?*Route {
    var ret: ?*Route = null;

    for (routes.items) |*route| {
        if (dest.subnet(route.netmask).eql(route.network) or dest.eql(.limited_broadcast)) {
            if (ret) |candidate| {
                if (route.netmask.gte(candidate.netmask)) {
                    ret = route;
                }
            } else ret = route;
        }
    }

    return ret;
}

/// Lookup the interface for the given destination IP address.
pub fn ifaceLookup(dest: IpAddr) ?*Interface {
    const route = routeLookup(dest) orelse {
        return null;
    };

    return route.iface;
}

// =============================================================
// Data structures
// =============================================================

/// IP header.
///
/// This struct provides only the mandatory fields excluding options.
const Header = extern struct {
    /// Header Length / Version.
    ///
    /// Header length is divided by 4.
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
pub const HeaderReader = net.util.WireReader(Header);

/// Protocols encapsulated in IP packets.
///
/// See https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml
pub const Protocol = enum(u8) {
    /// IP.
    ip = 0,
    /// ICMP.
    icmp = 1,
    /// UDP.
    udp = 17,

    /// All other unrecognized protocols.
    _,

    /// Functions to handle the protocol data encapsulated in IP packets.
    pub const Vtable = struct {
        /// Process the incoming data.
        input: *const fn (hdr: HeaderReader, iface: *const Interface, data: []const u8) net.Error!void,
    };

    /// Get the handler for the given protocol.
    fn getHandler(self: Protocol) ?Protocol.Vtable {
        return switch (self) {
            .icmp => @import("icmp.zig").vtable,
            .udp => @import("udp.zig").vtable,
            else => null,
        };
    }
};

// =============================================================
// Debug
// =============================================================

/// Print an IP packet data.
fn print(data: []const u8, logger: anytype) void {
    const io = net.util.WireReader(Header).new(data);
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
const trace = urd.trace.scoped(.net, .ip);
const Allocator = std.mem.Allocator;
const common = @import("common");
const rtt = common.rtt;
const util = common.util;
const urd = @import("urthr");
const net = urd.net;
const NetBuffer = @import("NetBuffer.zig");
