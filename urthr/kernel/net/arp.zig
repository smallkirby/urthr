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
    if (op != .request and op != .reply) {
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
    try cache.update(spa, sha, .resolved);

    // Debug print the ARP packet.
    log.debug("ARP packet: haddr_type={}, paddr_type={}, op={}", .{
        haddr_type,
        paddr_type,
        op,
    });
    log.debug("  Source: {f} , {f}", .{ io_addr.read(.sha), io_addr.read(.spa) });
    log.debug("  Target: {f} , {f}", .{ io_addr.read(.tha), io_addr.read(.tpa) });

    if (op == .reply) {
        return;
    }

    var nbuf = try NetBuffer.init(
        @sizeOf(GenericHeader) + @sizeOf(AddrInfoMacIp),
        urd.mem.getGeneralAllocator(),
    );
    errdefer nbuf.deinit();

    try writeGenericHeader(&nbuf, .reply);

    // Construct address info.
    const shdr = try nbuf.append(@sizeOf(AddrInfoMacIp));
    const sio = net.WireWriter(AddrInfoMacIp).new(shdr);
    sio.write(.sha, io_addr.read(.tha));
    sio.write(.spa, io_addr.read(.tpa));
    sio.write(.tha, io_addr.read(.sha));
    sio.write(.tpa, io_addr.read(.spa));

    try net.enqueueTx(dev, &io_addr.read(.sha).value, .arp, nbuf);
}

/// Send an ARP request.
pub fn request(iface: *const net.Interface, ip: net.ip.IpAddr) net.Error!void {
    if (iface.family != .ipv4) {
        return net.Error.Unsupported;
    }
    const dev = iface.device.?;
    const ip_iface: *const net.ip.IpInterface = @ptrCast(@alignCast(iface.ctx));

    var nbuf = try NetBuffer.init(
        @sizeOf(GenericHeader) + @sizeOf(AddrInfoMacIp),
        urd.mem.getGeneralAllocator(),
    );
    errdefer nbuf.deinit();

    try writeGenericHeader(&nbuf, .request);

    // Construct address info.
    const shdr = try nbuf.append(@sizeOf(AddrInfoMacIp));
    const sio = net.WireWriter(AddrInfoMacIp).new(shdr);
    const sha: *const ether.MacAddr = @ptrCast(dev.getAddr());
    sio.write(.sha, sha.*);
    sio.write(.spa, ip_iface.unicast);
    sio.write(.tha, net.ether.MacAddr.empty);
    sio.write(.tpa, ip);

    try net.enqueueTx(dev, dev.getBroadcastAddr(), .arp, nbuf);
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
        return switch (entry.state) {
            .resolved, .static => @memcpy(hw[0..ether.MacAddr.length], &entry.mac.value),
            .wip => net.Error.Resolving,
        };
    }

    // Insert a wip entry so pending packets can be queued against it.
    try cache.update(ip, undefined, .wip);
    // Send ARP request to resolve the address.
    try request(iface, ip);

    return net.Error.Resolving;
}

/// Write the common ARP GenericHeader with the given operation.
fn writeGenericHeader(nbuf: *NetBuffer, op: Op) net.Error!void {
    const ghdr = try nbuf.append(@sizeOf(GenericHeader));
    const gio = net.WireWriter(GenericHeader).new(ghdr);
    gio.write(.haddr_type, .ether);
    gio.write(.paddr_type, .ip);
    gio.write(.haddr_len, @sizeOf(ether.MacAddr));
    gio.write(.paddr_len, @sizeOf(net.ip.IpAddr));
    gio.write(.op, op);
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

    /// Maximum number of packets queued per cache entry waiting for ARP resolution.
    const pending_queue_capacity = 3;

    /// Packet pending ARP resolution.
    const PendingPacket = struct {
        /// Device to transmit on.
        device: *net.Device,
        /// Packet data buffer.
        buf: NetBuffer,
    };

    /// List type of pending packets.
    const PendingList = std.array_list.Aligned(PendingPacket, null);

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
        /// Packets waiting for ARP resolution.
        pending: PendingList = .{},

        /// Free the pending list backing memory.
        ///
        /// Does NOT free individual packet buffers. Callers must consume or free them first.
        fn clearPending(self: *CacheEntry, allocator: Allocator) void {
            self.pending.deinit(allocator);
        }
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
    pub fn update(ip: net.ip.IpAddr, mac: ether.MacAddr, state: State) Allocator.Error!void {
        // TODO: should take a lock.

        if (instance.getPtr(ip)) |entry| {
            const old_state = entry.state;
            entry.timestamp = urd.time.getCurrentTimestamp();
            entry.state = state;
            entry.mac = mac;

            if (old_state == .wip and state == .resolved) {
                flushPending(entry);
            }
        } else {
            try instance.put(ip, .{
                .ip = ip,
                .mac = mac,
                .timestamp = urd.time.getCurrentTimestamp(),
                .state = state,
            });
        }
    }

    /// Send all pending packets now that the MAC address is resolved.
    fn flushPending(entry: *CacheEntry) void {
        for (entry.pending.items) |*pkt| {
            net.enqueueTx(
                pkt.device,
                entry.mac.value[0..pkt.device.addr_len],
                .ip,
                pkt.buf,
            ) catch |e| {
                log.debug("Failed to enqueue packet for ARP resolution: {t}", .{e});
                // If the transmission fails, this functions owns the packet buffer.
                pkt.buf.deinit();
            };
        }

        entry.clearPending(urd.mem.getGeneralAllocator());
    }

    /// Enqueue a packet to wait for ARP resolution of the given IP address.
    ///
    /// Takes ownership of buf.
    /// If the entry does not exist or the queue is full, buf is freed and dropped immediately.
    pub fn enqueuePending(ip: net.ip.IpAddr, device: *net.Device, buf: NetBuffer) Allocator.Error!void {
        // TODO: should take a lock.
        const entry = find(ip) orelse {
            return buf.deinit();
        };
        if (entry.pending.items.len >= pending_queue_capacity) {
            return buf.deinit();
        }

        const allocator = urd.mem.getGeneralAllocator();
        try entry.pending.append(allocator, .{
            .device = device,
            .buf = buf,
        });
    }

    /// Delete the cache entry for the given IP address.
    ///
    /// This function ignores the case where the entry does not exist.
    ///
    /// Caller must ensure that the pending packets are consumed or freed.
    pub fn delete(ip: net.ip.IpAddr) void {
        // TODO: should take a lock.
        if (find(ip)) |entry| {
            entry.clearPending(urd.mem.getGeneralAllocator());
        }
        _ = instance.remove(ip);
    }

    /// Find the cache entry for the given IP address.
    fn find(ip: net.ip.IpAddr) ?*CacheEntry {
        // TODO: should take a lock.
        return instance.getPtr(ip);
    }

    /// Cleanup stale cache entries.
    fn cleanup() void {
        // TODO: should take a lock.

        // Collect stale IPs first to avoid modifying the HashMap while iterating.
        const max_stale_count = 16;
        var stale: [max_stale_count]net.ip.IpAddr = undefined;
        var stale_count: usize = 0;
        const now = urd.time.getCurrentTimestamp();

        var it = instance.valueIterator();
        while (it.next()) |entry| {
            const staled = now - entry.timestamp > cleanup_interval_us;
            if (entry.state != .static and staled) {
                stale[stale_count] = entry.ip;
                stale_count += 1;
            }

            if (stale_count >= max_stale_count) {
                break;
            }
        }
        for (stale[0..stale_count]) |ip| {
            delete(ip);
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
