//! ARP protocol implementation.

pub const vtable = net.Protocol.Vtable{
    .input = inputImpl,
};

/// Handle an incoming ARP packet.
fn inputImpl(dev: *net.Device, data: []const u8) net.Error!void {
    if (data.len < @sizeOf(GenericHeader)) {
        return net.Error.InvalidPacket;
    }

    const gio = net.util.WireReader(GenericHeader).new(data);
    const haddr_type = gio.read(.haddr_type);
    const paddr_type = gio.read(.paddr_type);
    const op = gio.read(.op);

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

    // Update ARP cache.
    const aio = net.util.WireReader(AddrInfoMacIp).new(data[@sizeOf(GenericHeader)..]);
    const sha = aio.read(.sha);
    const spa = aio.read(.spa);
    try cache.update(spa, sha, .resolved);

    // Debug print the packet.
    print(data, trace);

    switch (op) {
        // Request: Send back a reply.
        .request => {
            var nbuf = try NetBuffer.init(
                @sizeOf(GenericHeader) + @sizeOf(AddrInfoMacIp),
                urd.mem.getGeneralAllocator(),
            );
            errdefer nbuf.deinit();

            try writeGenericHeader(&nbuf, .reply);

            // Construct address info.
            const shdr = try nbuf.append(@sizeOf(AddrInfoMacIp));
            const sio = net.util.WireWriter(AddrInfoMacIp).new(shdr);
            const hwadr = MacAddr.from(dev.getAddr());
            sio.write(.sha, hwadr);
            sio.write(.spa, aio.read(.tpa));
            sio.write(.tha, aio.read(.sha));
            sio.write(.tpa, aio.read(.spa));

            try net.enqueueTx(dev, &aio.read(.sha).value, .arp, nbuf);
        },

        // Reply: No action needed.
        .reply => {},

        // Unrecognized operation.
        else => {},
    }
}

/// Send an ARP request.
pub fn request(iface: *net.Interface, ip: IpAddr) net.Error!void {
    if (iface.family != .ipv4) {
        return net.Error.Unsupported;
    }

    const dev = iface.device orelse {
        log.warn("No device registered for the interface.", .{});
        return net.Error.Unavailable;
    };
    const ipif = net.ip.Interface.downcast(iface);

    var nbuf = try NetBuffer.init(
        @sizeOf(GenericHeader) + @sizeOf(AddrInfoMacIp),
        urd.mem.getGeneralAllocator(),
    );
    errdefer nbuf.deinit();

    try writeGenericHeader(&nbuf, .request);

    // Construct address info.
    const shdr = try nbuf.append(@sizeOf(AddrInfoMacIp));
    const sio = net.util.WireWriter(AddrInfoMacIp).new(shdr);
    const sha: *const MacAddr = @ptrCast(dev.getAddr());
    sio.write(.sha, sha.*);
    sio.write(.spa, ipif.unicast);
    sio.write(.tha, .empty);
    sio.write(.tpa, ip);

    try net.enqueueTx(dev, dev.getBroadcastAddr(), .arp, nbuf);
}

/// Write the common ARP GenericHeader with the given operation.
fn writeGenericHeader(nbuf: *NetBuffer, op: Op) net.Error!void {
    const ghdr = try nbuf.append(@sizeOf(GenericHeader));
    const gio = net.util.WireWriter(GenericHeader).new(ghdr);
    gio.write(.haddr_type, .ether);
    gio.write(.paddr_type, .ip);
    gio.write(.haddr_len, @sizeOf(MacAddr));
    gio.write(.paddr_len, @sizeOf(IpAddr));
    gio.write(.op, op);
}

// =============================================================
// Address resolution
// =============================================================

/// Resolve the MAC address for the given IP address on the specified interface.
pub fn resolve(iface: *net.Interface, ip: IpAddr, hw: []u8) net.Error!void {
    const device = iface.device orelse {
        log.warn("No device registered for the interface.", .{});
        return net.Error.Unavailable;
    };

    if (iface.family != .ipv4) {
        return net.Error.Unsupported;
    }
    if (device.dev_type != .ether) {
        return net.Error.Unsupported;
    }

    if (cache.find(ip)) |entry| return switch (entry.state) {
        .resolved, .static => @memcpy(hw[0..MacAddr.length], &entry.mac.value),
        .wip => net.Error.Resolving,
    };

    // Insert a wip entry so pending packets can be queued against it.
    try cache.update(ip, undefined, .wip);
    // Send ARP request to resolve the address.
    try request(iface, ip);

    return net.Error.Resolving;
}

/// ARP cache management.
pub const cache = struct {
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

    /// ARP cache hashmap type.
    const Cache = std.AutoHashMap(IpAddr, CacheEntry);

    /// Cache entry.
    const CacheEntry = struct {
        /// IP address (key).
        ip: IpAddr,
        /// MAC address (value).
        mac: MacAddr,
        /// Timestamp of the last update.
        timestamp: urd.time.Ktimestamp,
        /// Cache entry state.
        state: State,
        /// Packets waiting for ARP resolution.
        pending: PendingList = .{},

        /// Free the pending list backing memory.
        ///
        /// Does NOT free individual packet buffers. Callers must consume or free them first.
        fn clearPending(self: *CacheEntry) void {
            self.pending.deinit(_allocator);
        }
    };

    /// ARP cache instance.
    var instance: Cache = undefined;

    /// Lock to protect the cache instance.
    var lock: SpinLock = .{};

    /// General-purpose allocator.
    var _allocator: Allocator = undefined;

    /// Interval for cleaning up stale cache entries in microseconds.
    const cleanup_interval_us = 10 * std.time.us_per_s;

    /// Initialize ARP cache.
    pub fn init(allocator: Allocator) Allocator.Error!void {
        instance = .init(allocator);
        _allocator = allocator;

        // Register ARP cache cleanup timer.
        _ = try urd.time.register(cleanup_interval_us, cleanupIrq);
    }

    /// Find the cache entry for the given IP address.
    fn find(ip: IpAddr) ?*CacheEntry {
        const ie = lock.lockDisableIrq();
        defer lock.unlockRestoreIrq(ie);

        return instance.getPtr(ip);
    }

    /// Register or update the MAC address for the given IP address.
    fn update(ip: IpAddr, mac: MacAddr, state: State) Allocator.Error!void {
        const ie = lock.lockDisableIrq();
        defer lock.unlockRestoreIrq(ie);
        const ts = urd.time.getCurrentTimestamp();

        if (instance.getPtr(ip)) |entry| {
            // Update existing entry.
            const old_state = entry.state;
            entry.timestamp = ts;
            entry.state = state;
            entry.mac = mac;

            if (old_state == .wip and state == .resolved) {
                // Address resolved. Flush pending packets.
                flushPending(entry);
            }
        } else {
            // Register new entry.
            try instance.put(ip, .{
                .ip = ip,
                .mac = mac,
                .timestamp = ts,
                .state = state,
            });
        }
    }

    /// Send all pending packets that are waiting for the given entry to be resolved.
    fn flushPending(entry: *CacheEntry) void {
        for (entry.pending.items) |*pkt| net.enqueueTx(
            pkt.device,
            entry.mac.value[0..pkt.device.addr_len],
            .ipv4,
            pkt.buf,
        ) catch |e| {
            log.debug("Failed to enqueue packet for ARP resolution: {t}", .{e});
            // If the transmission fails, this functions owns the packet buffer.
            pkt.buf.deinit();
        };

        entry.clearPending();
    }

    /// Enqueue a packet to wait for ARP resolution of the given IP address.
    ///
    /// Queued packets are transmitted when the address is resolved.
    /// Takes ownership of `buf`.
    /// If the entry does not exist or the queue is full, buf is freed and dropped immediately.
    pub fn enqueuePending(ip: IpAddr, device: *net.Device, buf: NetBuffer) Allocator.Error!void {
        const ie = lock.lockDisableIrq();
        defer lock.unlockRestoreIrq(ie);

        const entry = instance.getPtr(ip) orelse {
            return buf.deinit();
        };
        if (entry.pending.items.len >= pending_queue_capacity) {
            return buf.deinit();
        }

        try entry.pending.append(_allocator, .{
            .device = device,
            .buf = buf,
        });
    }

    /// Delete the cache entry for the given IP address.
    ///
    /// This function ignores the case where the entry does not exist.
    pub fn delete(ip: IpAddr) void {
        const ie = lock.lockDisableIrq();
        defer lock.unlockRestoreIrq(ie);

        if (instance.getPtr(ip)) |entry| {
            for (entry.pending.items) |*pkt| {
                pkt.buf.deinit();
            }
            entry.clearPending();
        }
        _ = instance.remove(ip);
    }

    /// Cleanup stale cache entries.
    ///
    /// Called from IRQ context.
    fn cleanupIrq() void {
        const max_stale_count = 16;
        var stale: [max_stale_count]IpAddr = undefined;
        var stale_count: usize = 0;
        const now = urd.time.getCurrentTimestamp();

        // Collect stale IPs first to avoid modifying the HashMap while iterating.
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

        // Pending packets of deleted entries are dropped.
        for (stale[0..stale_count]) |ip| {
            delete(ip);
        }
    }
};

// =============================================================
// Data structures
// =============================================================

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
    sha: MacAddr align(1),
    /// Sender protocol address.
    spa: IpAddr align(1),
    /// Target hardware address.
    tha: MacAddr align(1),
    /// Target protocol address.
    tpa: IpAddr align(1),
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

// =============================================================
// Debug
// =============================================================

fn print(data: []const u8, logger: anytype) void {
    const gio = net.util.WireReader(GenericHeader).new(data);

    logger("ARP packet: size={d}", .{data.len});
    logger("  haddr_type : {s}", .{@tagName(gio.read(.haddr_type))});
    logger("  paddr_type : {s}", .{@tagName(gio.read(.paddr_type))});
    logger("  op         : {s}", .{@tagName(gio.read(.op))});

    switch (gio.read(.op)) {
        .request, .reply => {
            const aio = net.util.WireReader(AddrInfoMacIp).new(data[@sizeOf(GenericHeader)..]);
            logger("  Source: {f}, {f}", .{ aio.read(.sha), aio.read(.spa) });
            logger("  Target: {f}, {f}", .{ aio.read(.tha), aio.read(.tpa) });
        },
        else => {},
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.arp);
const Allocator = std.mem.Allocator;
const common = @import("common");
const urd = @import("urthr");
const trace = urd.trace.scoped(.net, .arp);
const SpinLock = urd.SpinLock;
const net = urd.net;
const IpAddr = net.ip.IpAddr;
const MacAddr = net.ether.MacAddr;
const ether = @import("ether.zig");
const NetBuffer = @import("NetBuffer.zig");
