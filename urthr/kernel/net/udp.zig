//! UDP: User Datagram Protocol implementation.

pub const vtable = net.ip.Protocol.Vtable{
    .input = inputImpl,
};

/// Handle an incoming UDP packet.
fn inputImpl(
    iphdr: net.ip.HeaderReader,
    iface: *const net.ip.Interface,
    data: []const u8,
) net.Error!void {
    if (data.len < @sizeOf(Header)) {
        log.warn("Too small UDP packet: {d}", .{data.len});
        return net.Error.InvalidPacket;
    }

    var pseudo_data = std.mem.zeroInit(PseudoHeader, .{});
    const pseudo = net.util.WireWriter(PseudoHeader).new(&pseudo_data);
    const hdr = net.util.WireReader(Header).new(data);

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

        const pseudo_sum = net.util.calcChecksum(std.mem.asBytes(&pseudo_data));
        if (net.util.calcChecksumFrom(data, ~pseudo_sum) != 0) {
            log.warn("Invalid UDP checksum", .{});
            return net.Error.InvalidPacket;
        }
    }

    // Debug print the packet.
    print(data, log.debug);

    // Find the socket matching the destination endpoint.
    const local = Endpoint{
        .ip = iphdr.read(.dest_addr),
        .port = hdr.read(.dst),
    };
    const remote = Endpoint{
        .ip = iphdr.read(.src_addr),
        .port = hdr.read(.src),
    };
    const sock = sock_table.select(local) orelse {
        const src = iface.unicast;
        const dest = iphdr.read(.src_addr);
        try net.icmp.output(src, dest, .{ .unreach = {} });
        return;
    };

    // Push the payloda to the socket's pending data list.
    const payload = data[@sizeOf(Header)..hdr.read(.length)];
    try sock.push(remote, payload);
}

// =============================================================
// Socket API
// =============================================================

/// Open a UDP socket and return its descriptor.
///
/// The socket is not bound to any local endpoint at this point.
pub fn open() net.Error!usize {
    const sock = try sock_table.allocate();
    return sock_table.indexOf(sock);
}

/// Close the socket associated with the given descriptor.
pub fn close(desc: usize) net.Error!void {
    const sock = sock_table.get(desc);
    rtt.expectEqual(.open, sock.state);
    sock_table.release(sock);
}

/// Bind the socket to the local endpoint.
pub fn bind(desc: usize, local: Endpoint) net.Error!void {
    const sock = sock_table.get(desc);
    rtt.expectEqual(.open, sock.state);

    // Check if the local endpoint is already used by another socket.
    if (sock_table.select(local)) |_| {
        return net.Error.Unavailable;
    }

    sock.ep = local;
}

/// Socket table instance.
var sock_table: SocketTable = .{};

const Endpoint = struct {
    /// IP address.
    ip: IpAddr,
    /// UDP port.
    port: Port,

    const empty = Endpoint{ .ip = .any, .port = 0 };
};

/// Packet data waiting for being received by the socket.
const PendingEntry = struct {
    /// Sender endpoint of the packet.
    remote: Endpoint,
    /// Payload of the packet.
    ///
    /// The data is copied from the RX buffer and owned by the socket.
    /// Receivers should free the buffer after consuming the data.
    data: []const u8,

    /// List head for linkling pending entries.
    _node: std.DoublyLinkedList.Node = .{},
};

const Socket = struct {
    /// State of socket.
    state: State,
    /// Local endpoint of the socket.
    ep: Endpoint,
    /// List of pending packets.
    pending_data: std.DoublyLinkedList,

    const State = enum {
        ///
        free,
        /// Socket is open.
        open,
        ///
        closing,
    };

    /// Push the given UDP packet data to the socket's pending data list.
    ///
    /// Given `data` is copied and can be freed by the caller.
    fn push(self: *Socket, remote: Endpoint, data: []const u8) Allocator.Error!void {
        const allocator = urd.mem.getGeneralAllocator();
        const entry = try allocator.create(PendingEntry);
        errdefer allocator.destroy(entry);

        // Copy packet data.
        const buf = try allocator.dupe(u8, data);
        errdefer allocator.free(buf);

        // Push the entry to the pending data list.
        entry.* = .{
            .remote = remote,
            .data = buf,
        };
        self.pending_data.append(&entry._node);
    }
};

const SocketTable = struct {
    const Self = @This();

    /// Socket table.
    sockets: [max_sockets]Socket = [_]Socket{.{
        .state = .free,
        .ep = .empty,
        .pending_data = .{},
    }} ** max_sockets,

    /// Lock to protect a socket table.
    lock: SpinLock = .{},

    /// Maximum number of sockets to be open at the same time.
    const max_sockets = 10;

    /// Find a free socket and open it.
    fn allocate(self: *Self) net.Error!*Socket {
        const ie = self.lock.lockDisableIrq();
        defer self.lock.unlockRestoreIrq(ie);

        for (&self.sockets) |*s| {
            if (s.state == .free) {
                s.* = Socket{
                    .state = .open,
                    .ep = .empty,
                    .pending_data = .{},
                };
                return s;
            }
        } else return net.Error.OutOfMemory;
    }

    /// Release to close the given socket.
    fn release(self: *Self, sock: *const Socket) void {
        _ = self.indexOf(sock);

        const ie = self.lock.lockDisableIrq();
        defer self.lock.unlockRestoreIrq(ie);

        // Free pending data.
        const allocator = urd.mem.getGeneralAllocator();
        var iter = sock.pending_data.first;
        while (iter) |node| : (iter = node.next) {
            const pending: *const PendingEntry = @fieldParentPtr("_node", iter);
            allocator.free(pending.data);
        }

        // Invalidate the socket entry.
        sock.* = .{
            .state = .free,
            .ep = .empty,
        };
    }

    /// Get a socket by its descriptor.
    fn get(self: *Self, desc: usize) *Socket {
        rtt.expect(desc < self.sockets.len);
        return &self.sockets[desc];
    }

    /// Select the socket matching the given local endpoint.
    ///
    /// .any IP address matches any remote IP address.
    fn select(self: *Self, local: Endpoint) ?*Socket {
        const ie = self.lock.lockDisableIrq();
        defer self.lock.unlockRestoreIrq(ie);

        for (&self.sockets) |*s| {
            if (s.state != .open) continue;
            if (s.ep.port != local.port) continue;
            if (s.ep.ip.eql(local.ip) or s.ep.ip.eql(.any) or local.ip.eql(.any)) {
                return s;
            }
        } else return null;
    }

    /// Get the index of the given socket in the table.
    fn indexOf(self: *Self, sock: *const Socket) usize {
        const index = (@intFromPtr(&self.sockets) - @intFromPtr(sock)) / @sizeOf(Socket);
        rtt.expect(index < self.sockets.len);
        return index;
    }
};

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
    const io = net.util.WireReader(Header).new(data);
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
const Allocator = std.mem.Allocator;
const common = @import("common");
const rtt = common.rtt;
const urd = @import("urthr");
const SpinLock = urd.SpinLock;
const net = urd.net;
const IpAddr = net.ip.IpAddr;
