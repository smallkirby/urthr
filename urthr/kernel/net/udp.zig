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
    print(data, trace);

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
        trace("No socket found for local endpoint {f}:{d}, remote endpoint {f}:{d}", .{ src, local.port, dest, remote.port });
        return try net.icmp.output(src, dest, .{ .unreach = {} });
    };

    // Push the payloda to the socket's pending data list.
    const payload = data[@sizeOf(Header)..hdr.read(.length)];
    try sock.push(remote, payload);
}

/// Send a UDP packet to the remote endpoint.
fn output(src: Endpoint, dest: Endpoint, data: []const u8) net.Error!void {
    var nbuf = try net.NetBuffer.init(
        @sizeOf(Header) + data.len,
        urd.mem.getGeneralAllocator(),
    );
    errdefer nbuf.deinit();

    // Construct UDP header.
    const len: u16 = @intCast(@sizeOf(Header) + data.len);
    const hdrp = try nbuf.append(@sizeOf(Header));
    const hdr = net.util.WireWriter(Header).new(hdrp);
    hdr.write(.src, src.port);
    hdr.write(.dst, dest.port);
    hdr.write(.length, len);
    hdr.write(.checksum, 0);

    // Copy payload data.
    const payload = try nbuf.append(data.len);
    @memcpy(payload, data);

    // Construct pseudo header for checksum calculation.
    var pseudo_data = std.mem.zeroInit(PseudoHeader, .{});
    const pseudo = net.util.WireWriter(PseudoHeader).new(&pseudo_data);
    pseudo.write(.src, src.ip);
    pseudo.write(.dst, dest.ip);
    pseudo.write(.zero, 0);
    pseudo.write(.protocol, .udp);
    pseudo.write(.length, len);

    // Calculate checksum.
    const pseudo_sum = net.util.calcChecksum(std.mem.asBytes(&pseudo_data));
    const sum = net.util.calcChecksumFrom(nbuf.data(), ~pseudo_sum);
    hdr.write(.checksum, if (sum == 0) 0xFFFF else sum);

    // Send the packet via IP layer.
    try net.ip.output(src.ip, dest.ip, .udp, &nbuf);
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
pub fn close(desc: usize) void {
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

const RecvResult = struct {
    /// Data received from the socket.
    ///
    /// Points to the buffer passed to `recvfrom()`.
    data: []const u8,
    /// Remote endpoint of the received packet.
    remote: Endpoint,
};

/// Receive a UDP data from the socket.
///
/// This function blocks until a UDP packet is received for the socket.
/// If the out buffer length is smaller than the received packet, the packet is truncated and lost.
pub fn recvfrom(desc: usize, buf: []u8) RecvResult {
    const sock = sock_table.get(desc);
    rtt.expectEqual(.open, sock.state);

    const pending: *const PendingEntry = while (true) {
        const ie = sock.lock.lockDisableIrq();
        defer sock.lock.unlockRestoreIrq(ie);

        // Check if there is pending data.
        if (sock.pending_data.popFirst()) |node| {
            break @fieldParentPtr("_node", node);
        }

        // TODO: should return an error if the socket is closed while waiting

        // Wait for incoming data.
        sock.waitq.wait(&sock.lock);
    };

    const len = @min(buf.len, pending.data.len);
    @memcpy(buf[0..len], pending.data[0..len]);
    sock.free(pending);

    return .{
        .data = buf[0..len],
        .remote = pending.remote,
    };
}

/// Send a UDP packet to the remote endpoint via the socket.
///
/// If the socket is not bound to a local endpoint, appropriate interface is selected.
pub fn sendto(desc: usize, data: []const u8, remote: Endpoint) net.Error!void {
    const sock = sock_table.get(desc);
    rtt.expectEqual(.open, sock.state);

    const local = &sock.ep;
    // Select a local port.
    if (local.port == 0) {
        local.port = selectDynamicPort();
    }
    // Select a local IP.
    if (local.ip.eql(.any)) {
        const iface = net.ip.ifaceLookup(remote.ip) orelse {
            log.err("No interface found for remote IP: {f}", .{remote.ip});
            return net.Error.Unavailable;
        };
        local.ip = iface.unicast;
    }

    try output(local.*, remote, data);
}

/// Range of dynamic UDP ports that can be used for automatic local port assignment.
const dynamic_port = Range{
    .start = 49152,
    .end = 65535,
};

/// Select an available dynamic port for automatic local port assignment.
fn selectDynamicPort() Port {
    for (dynamic_port.start..dynamic_port.end) |port| {
        _ = sock_table.select(.{ .ip = .any, .port = @intCast(port) }) orelse {
            return @intCast(port);
        };
    } else @panic("UDP dynamic port exhaustion");
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
    /// Wait queue to wake the receiver thread.
    waitq: urd.WaitQueue = .{},
    /// Lock to protect the socket state and pending data.
    lock: SpinLock = .{},

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
        {
            const ie = self.lock.lockDisableIrq();
            defer self.lock.unlockRestoreIrq(ie);
            entry.* = .{
                .remote = remote,
                .data = buf,
            };
            self.pending_data.append(&entry._node);
        }

        // Wake a receiver thread.
        _ = self.waitq.wake();
    }

    /// Free given pending entry data.
    fn free(_: *Socket, entry: *const PendingEntry) void {
        const allocator = urd.mem.getGeneralAllocator();
        allocator.free(entry.data);
        allocator.destroy(entry);
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
    fn release(self: *Self, sock: *Socket) void {
        _ = self.indexOf(sock);

        const ie = self.lock.lockDisableIrq();
        defer self.lock.unlockRestoreIrq(ie);

        // Free pending data.
        const allocator = urd.mem.getGeneralAllocator();
        var iter = sock.pending_data.first;
        while (iter) |node| : (iter = node.next) {
            const pending: *const PendingEntry = @fieldParentPtr("_node", node);
            allocator.free(pending.data);
        }

        // Invalidate the socket entry.
        sock.* = .{
            .state = .free,
            .ep = .empty,
            .pending_data = .{},
        };

        // Wake all waiting threads.
        while (sock.waitq.wake()) {}
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

    logger("UDP: {d} -> {d}, length={d}, checksum={X:0>4}", .{
        io.read(.src),
        io.read(.dst),
        io.read(.length),
        io.read(.checksum),
    });
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.udp);
const trace = urd.trace.scoped(.net, .udp);
const Allocator = std.mem.Allocator;
const common = @import("common");
const Range = common.Range;
const rtt = common.rtt;
const urd = @import("urthr");
const SpinLock = urd.SpinLock;
const net = urd.net;
const IpAddr = net.ip.IpAddr;
