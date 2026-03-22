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

    // Update ARP cache.
    const sha = io_addr.read(.sha);
    const spa = io_addr.read(.spa);
    try cache.update(spa, sha);

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

/// Resolve the MAC address for the given IP address on the specified interface.
pub fn resolve(iface: *const net.Interface, ip: net.ip.IpAddr, hw: []u8) net.Error!void {
    if (iface.family != .ipv4) {
        return net.Error.Unsupported;
    }
    if (iface.device.?.dev_type != .ether) {
        return net.Error.Unsupported;
    }

    if (cache.find(ip)) |entry| {
        if (entry.state == .resolved) {
            @memcpy(hw[0..ether.MacAddr.length], &entry.mac.value);
            return;
        }
    }

    return net.Error.Unavailable;
}

// =============================================================
// Address resolution
// =============================================================

/// ARP cache management.
pub const cache = struct {
    /// ARP cache hashmap type.
    const Cache = std.AutoHashMap(net.ip.IpAddr, CacheEntry);

    /// State of the cache entry.
    const State = enum {
        /// The entry is being resolved.
        wip,
        /// The entry is resolved and valid.
        resolved,
        /// The entry is registered statically.
        static,
    };

    /// Cache entry.
    const CacheEntry = struct {
        /// IP address (key).
        ip: net.ip.IpAddr,
        /// MAC address (value).
        mac: ether.MacAddr,
        /// Timestamp of the last update.
        timestamp: urd.time.Ktimestamp,
        /// Cache entry state.
        state: State,
    };

    /// ARP cache instance.
    var instance: Cache = undefined;

    /// Interval for cleaning up stale cache entries in microseconds.
    const cleanup_interval_us = 10 * std.time.us_per_s;

    /// Initialize ARP cache.
    pub fn init(allocator: Allocator) Allocator.Error!void {
        instance = .init(allocator);

        // Register ARP cache cleanup timer.
        _ = try urd.time.register(cleanup_interval_us, cleanup);
    }

    /// Register or update the MAC address for the given IP address.
    pub fn update(ip: net.ip.IpAddr, mac: ether.MacAddr) Allocator.Error!void {
        // TODO: should take a lock.
        try instance.put(ip, .{
            .ip = ip,
            .mac = mac,
            .timestamp = urd.time.getCurrentTimestamp(),
            .state = .resolved,
        });
    }

    /// Delete the cache entry for the given IP address.
    ///
    /// This function ignores the case where the entry does not exist.
    pub fn delete(ip: net.ip.IpAddr) void {
        // TODO: should take a lock.
        _ = instance.remove(ip);
    }

    /// Find the cache entry for the given IP address.
    fn find(ip: net.ip.IpAddr) ?CacheEntry {
        // TODO: should take a lock.
        return instance.get(ip);
    }

    /// Cleanup stale cache entries.
    fn cleanup() void {
        const now = urd.time.getCurrentTimestamp();
        var it = instance.valueIterator();
        while (it.next()) |entry| {
            const staled = now - entry.timestamp > cleanup_interval_us;
            if (entry.state == .resolved and staled) {
                delete(entry.ip);
            }
        }
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.arp);
const Allocator = std.mem.Allocator;
const common = @import("common");
const urd = @import("urthr");
const net = urd.net;
const ether = @import("ether.zig");
const NetBuffer = @import("NetBuffer.zig");
