//! TCP: Transmission Control Protocol
//!
//! ref. https://datatracker.ietf.org/doc/html/rfc793

pub const vtable = net.ip.Protocol.Vtable{
    .input = inputImpl,
};

/// Handle an incoming TCP packet.
fn inputImpl(
    iphdr: net.ip.HeaderReader,
    iface: *const net.ip.Interface,
    data: []const u8,
) net.Error!void {
    if (data.len < @sizeOf(Header)) {
        log.warn("Too small TCP packet: {d}", .{data.len});
        return net.Error.InvalidPacket;
    }

    // Validate checksum.
    {
        var pseudo_data = std.mem.zeroInit(PseudoHeader, .{});
        const pseudo = net.util.WireWriter(PseudoHeader).new(&pseudo_data);

        pseudo.write(.src, iphdr.read(.src_addr));
        pseudo.write(.dst, iphdr.read(.dest_addr));
        pseudo.write(.zero, 0);
        pseudo.write(.protocol, .tcp);
        pseudo.write(.length, @intCast(data.len));

        const pseudo_sum = net.util.calcChecksum(std.mem.asBytes(&pseudo_data));
        if (net.util.calcChecksumFrom(data, ~pseudo_sum) != 0) {
            log.warn("Invalid TCP checksum", .{});
            return net.Error.InvalidPacket;
        }
    }

    const hdr = net.util.WireReader(Header).new(data);
    const local = Endpoint{
        .ip = iphdr.read(.dest_addr),
        .port = hdr.read(.dst),
    };
    const remote = Endpoint{
        .ip = iphdr.read(.src_addr),
        .port = hdr.read(.src),
    };

    // Validate source and destination IP address.
    if (local.ip.eql(.limited_broadcast) or
        local.ip.eql(iface.broadcast) or
        remote.ip.eql(.limited_broadcast) or
        remote.ip.eql(iface.broadcast))
    {
        // Broadcast is not supported.
        return;
    }

    print(data, trace);

    // Parse segment variables.
    const flags: Flags = hdr.read(.flags);
    var seg = Seg{
        .seq = hdr.read(.seq),
        .ack = hdr.read(.ack),
        .wnd = hdr.read(.window),
        .len = data.len - ((hdr.read(.offset) >> 4) * 4),
    };
    // SYN and FIN flags consume one sequence number.
    if (flags.syn) seg.len += 1;
    if (flags.fin) seg.len += 1;

    // Find a socket matching the endpoints.
    const sock = sock_table.select(local, remote) orelse {
        trace("No matching socket found for {f}:{d} -> {f}:{d}", .{ local.ip, local.port, remote.ip, remote.port });

        if (flags.rst) {
            // Ignore RST segments that do not match any socket.
            return;
        }
        if (flags.ack) {
            return outputSegment(
                local,
                remote,
                seg.ack,
                0,
                0,
                .reset,
                &.{},
            );
        } else {
            return outputSegment(
                local,
                remote,
                0,
                seg.seq + @as(u32, @intCast(seg.len)),
                0,
                .reset_ack,
                &.{},
            );
        }
    };

    var wakeup = false;
    sock.lock();
    defer {
        sock.unlock();
        if (wakeup) sock.wake();
    }

    // Handle the listening socket for a new connection request.
    switch (sock.state) {
        .listen => {
            if (flags.rst) {
                return;
            }
            if (flags.ack) {
                return outputSegment(
                    local,
                    remote,
                    seg.ack,
                    0,
                    0,
                    .reset,
                    &.{},
                );
            }
            if (flags.syn) {
                sock.local = local;
                sock.remote = remote;
                sock.rcv = .{
                    .wnd = @intCast(sock.buf.len),
                    .nxt = seg.seq + 1,
                };
                sock.irs = seg.seq;
                sock.iss = rng().int(u32);

                try output(sock, .sync_ack, &.{});

                sock.snd.nxt = sock.iss + 1; // +1 for SYN
                sock.snd.una = sock.iss;
                sock.state = .syn_received;
                return;
            }
            // Ignore.
            return;
        },

        .syn_sent => {
            var valid_ack = false;

            if (flags.ack) {
                // Drop a segment with invalid ACK number.
                if (seg.ack <= sock.iss or seg.ack > sock.snd.nxt) {
                    return outputSegment(
                        local,
                        remote,
                        seg.ack,
                        0,
                        0,
                        .reset,
                        &.{},
                    );
                }
                if (sock.snd.una <= seg.ack and seg.ack <= sock.snd.nxt) {
                    valid_ack = true;
                }
            }

            if (flags.syn) {
                sock.rcv.nxt = seg.seq + 1;
                sock.irs = seg.seq;

                if (valid_ack) {
                    sock.snd.una = seg.ack;
                    sock.rtclean();
                }
                if (sock.snd.una > sock.iss) {
                    sock.state = .established;
                    try output(sock, .ackn, &.{});
                    sock.snd.wnd = seg.wnd;
                    sock.snd.wl1 = seg.seq;
                    sock.snd.wl2 = seg.ack;
                    wakeup = true;
                    return;
                }
            }

            return; // drop
        },

        else => {},
    }

    // Check the segment is acceptable according to the RCV.WND and RCV.NXT variables.
    if (sock.state == .syn_received or sock.state == .established) {
        const acceptable = if (seg.len == 0)
            (sock.rcv.wnd == 0 and seg.seq == sock.rcv.nxt) or
                (sock.rcv.nxt == seg.seq and seg.seq < sock.rcv.nxt + sock.rcv.wnd)
        else
            sock.rcv.wnd != 0 and
                ((sock.rcv.nxt <= seg.seq and seg.seq < sock.rcv.nxt + sock.rcv.wnd) or
                    (sock.rcv.nxt <= seg.seq + seg.len - 1 and seg.seq + seg.len - 1 < sock.rcv.nxt + sock.rcv.wnd));

        if (!acceptable) {
            if (flags.rst) try outputSegment(
                local,
                remote,
                seg.ack,
                0,
                0,
                .reset,
                &.{},
            );

            return;
        }
    }

    // Check validity of ACK number.
    if (!flags.ack) {
        return outputSegment(
            local,
            remote,
            0,
            seg.seq + @as(u32, @intCast(seg.len)),
            0,
            .reset_ack,
            &.{},
        );
    }
    switch (sock.state) {
        .syn_received => {
            if (sock.snd.una <= seg.ack and seg.ack <= sock.snd.nxt) {
                sock.state = .established;
                wakeup = true;
            } else {
                return outputSegment(
                    local,
                    remote,
                    seg.ack,
                    0,
                    0,
                    .reset,
                    &.{},
                );
            }
        },

        else => {},
    }
    switch (sock.state) {
        .syn_received, .established => {
            if (sock.snd.una < seg.ack and seg.ack <= sock.snd.nxt) {
                sock.snd.una = seg.ack;
                sock.rtclean();

                if (sock.snd.wl1 < seg.seq or (sock.snd.wl1 == seg.seq and sock.snd.wl2 <= seg.ack)) {
                    sock.snd.wl1 = seg.seq;
                    sock.snd.wl2 = seg.ack;
                    sock.snd.wnd = seg.wnd;
                }
            } else if (seg.ack < sock.snd.una) {
                // ignore duplicated ACK
            } else if (sock.snd.nxt < seg.ack) {
                // ACK to unsent data, send an ACK with the current RCV.NXT and RCV.WND.
                try output(sock, .ackn, &.{});
            }
        },

        else => {},
    }

    // Process the segment data.
    const hlen = (hdr.read(.offset) >> 4) * 4;
    const dlen = data.len - hlen;
    if (sock.state == .established and dlen != 0) {
        if (sock.rcv.nxt != seg.seq or sock.rcv.wnd < dlen) {
            // No support for out-of-order segments.
            try output(sock, .ackn, &.{});
        }

        // Copy data to the receive buffer.
        const offset = sock.buf.len - sock.rcv.wnd;
        @memcpy(sock.buf[offset .. offset + dlen], data[hlen..]);
        sock.rcv.nxt = seg.seq + @as(u32, @intCast(dlen));
        sock.rcv.wnd -= @intCast(dlen);

        // Send ACK.
        try output(sock, .ackn, &.{});

        // Wake up the thread waiting for data if any.
        wakeup = true;
    }
}

/// Output a TCP segment handling appropriately according to the socket's state.
fn output(sock: *Socket, flags: Flags, data: []const u8) net.Error!void {
    if ((flags.syn and flags.fin) and data.len != 0) {
        urd.unimplemented("TCP retransmission");
    }

    // Push to the retransmission queue when the segment consumes sequence space.
    const seq = if (flags.syn) sock.iss else sock.snd.nxt;
    if (flags.syn or flags.fin or data.len != 0) {
        try sock.rtpush(seq, flags, data);
    }

    // Output the segment.
    return outputSegment(
        sock.local,
        sock.remote,
        seq,
        sock.rcv.nxt,
        sock.rcv.wnd,
        flags,
        data,
    );
}

/// Output TCP segment.
fn outputSegment(
    local: Endpoint,
    remote: Endpoint,
    seq: u32,
    ack: u32,
    wnd: u16,
    flag: Flags,
    data: []const u8,
) net.Error!void {
    var nbuf = try net.NetBuffer.init(
        @sizeOf(Header) + data.len,
        urd.mem.getGeneralAllocator(),
    );
    errdefer nbuf.deinit();

    // Construct TCP header.
    const hdrp = try nbuf.append(@sizeOf(Header));
    const hdr = net.util.WireWriter(Header).new(hdrp);
    hdr.write(.src, local.port);
    hdr.write(.dst, remote.port);
    hdr.write(.seq, seq);
    hdr.write(.ack, ack);
    hdr.write(.offset, (@sizeOf(Header) / 4) << 4);
    hdr.write(.flags, flag);
    hdr.write(.window, wnd);
    hdr.write(.checksum, 0);
    hdr.write(.urgent, 0);

    // Copy payload data.
    const payload = try nbuf.append(data.len);
    @memcpy(payload, data);

    // Construct pseudo header for checksum calculation.
    {
        var pseudo_data = std.mem.zeroInit(PseudoHeader, .{});
        const pseudo = net.util.WireWriter(PseudoHeader).new(&pseudo_data);

        pseudo.write(.src, local.ip);
        pseudo.write(.dst, remote.ip);
        pseudo.write(.zero, 0);
        pseudo.write(.protocol, .tcp);
        pseudo.write(.length, @intCast(@sizeOf(Header) + data.len));

        const pseudo_sum = net.util.calcChecksum(std.mem.asBytes(&pseudo_data));
        const sum = net.util.calcChecksumFrom(nbuf.data(), ~pseudo_sum);
        hdr.write(.checksum, sum);
    }

    print(nbuf.data(), trace);

    // Delegate the transmission to IP layer.
    try net.ip.output(local.ip, remote.ip, .tcp, &nbuf);
}

const Endpoint = struct {
    /// IP address.
    ip: IpAddr,
    /// TCP port.
    port: Port,

    const empty = Endpoint{ .ip = .any, .port = 0 };

    fn eql(self: Endpoint, other: Endpoint) bool {
        return self.ip.eql(other.ip) and self.port == other.port;
    }
};

// =============================================================
// Socket
// =============================================================

/// Initialize TCP protocol stack.
pub fn init() Allocator.Error!void {
    _ = try urd.time.register(retransmit_interval_us, timerFn);
}

/// Open a TCP socket.
pub fn open() net.Error!usize {
    const sock = try sock_table.allocate();
    return sock_table.indexOf(sock);
}

/// Bind a TCP socket to the given local endpoint.
pub fn bind(desc: usize, local: Endpoint) net.Error!void {
    const sock = sock_table.get(desc);

    if (sock.state != .closed) {
        return net.Error.Unavailable;
    }

    var lc = local;
    if (lc.port == 0) {
        lc.port = selectDynamicPort();
    }

    if (sock_table.select(lc, .empty) != null) {
        return net.Error.Unavailable;
    }

    sock.local = lc;
    sock.state = .closed;
}

/// Listen for incoming connection requests on a TCP socket.
///
/// This function blocks until a connection request is received.
/// This function does not create a new socket for the accepted connection.
pub fn listen(desc: usize) net.Error!void {
    const sock = sock_table.get(desc);

    if (sock.state != .closed) {
        return net.Error.Unavailable;
    }

    sock.remote = .empty;
    sock.state = .listen;

    // Wait until a connection is established.
    try waitSockEstablished(sock);

    // Set MSS for the established connection.
    const iface = net.ip.ifaceLookup(sock.remote.ip) orelse {
        log.err("connection failed: no interface for remote IP: {f}", .{sock.remote.ip});
        sock.state = .closed;
        return net.Error.Unavailable;
    };
    sock.mss = iface.base.device.?.mtu - @sizeOf(net.ip.Header) - @sizeOf(Header);
}

/// Connect a TCP socket to the given remote endpoint.
pub fn connect(desc: usize, remote: Endpoint) net.Error!void {
    const sock = sock_table.get(desc);

    if (sock.state != .closed) {
        log.err("connect: invalid socket state: {t}", .{sock.state});
        return net.Error.Unavailable;
    }

    // Select a local interface to reach the remote endpoint.
    if (sock.local.ip.eql(.any)) {
        const iface = net.ip.ifaceLookup(remote.ip) orelse {
            log.err("connect: no route to remote IP: {f}", .{remote.ip});
            return net.Error.Unavailable;
        };
        sock.local.ip = iface.unicast;
    }

    // Check if the local endpoint is already used by another socket.
    if (sock_table.select(sock.local, remote)) |s| {
        if (sock_table.indexOf(s) != desc) {
            log.err("connect: address already in use: {f}:{d}", .{ sock.local.ip, sock.local.port });
            return net.Error.Unavailable;
        }
    }

    sock.remote = remote;
    sock.rcv.wnd = @intCast(sock.buf.len);
    sock.iss = rng().int(u32);
    output(sock, .sync, &.{}) catch {
        sock.state = .closed;
        sock_table.release(sock);
        return net.Error.Unavailable;
    };
    sock.snd.una = sock.iss;
    sock.snd.nxt = sock.iss + 1; // +1 for SYN
    sock.state = .syn_sent;

    // Wait until a connection is established.
    try waitSockEstablished(sock);

    // Set MSS for the established connection.
    const iface = net.ip.ifaceLookup(sock.remote.ip) orelse {
        log.err("connection failed: no interface for remote IP: {f}", .{sock.remote.ip});
        sock.state = .closed;
        return net.Error.Unavailable;
    };
    sock.mss = iface.base.device.?.mtu - @sizeOf(net.ip.Header) - @sizeOf(Header);
}

/// Wait until a TCP socket is established.
fn waitSockEstablished(sock: *Socket) net.Error!void {
    var state = sock.state;
    while (true) {
        sock.wait();

        if (sock.state == state) {
            continue;
        }
        state = sock.state;

        switch (state) {
            .syn_received => continue,
            .established => break,
            else => {
                log.err("connection failed: unexpected state: {t}", .{state});
                sock.state = .closed;
                return net.Error.Unavailable;
            },
        }
    }
}

/// Close a TCP socket.
pub fn close(desc: usize) void {
    const sock = sock_table.get(desc);

    if (sock.state != .free and sock.state != .closed) {
        outputSegment(
            sock.local,
            sock.remote,
            sock.snd.nxt,
            sock.rcv.nxt,
            sock.rcv.wnd,
            .reset,
            &.{},
        ) catch {};
    }

    sock_table.release(sock);
}

/// Send data through a TCP socket.
///
/// This function blocks until all data is sent.
pub fn send(desc: usize, data: []const u8) net.Error!void {
    const sock = sock_table.get(desc);

    if (sock.state != .established) {
        log.warn("send: socket not established: {t}", .{sock.state});
        return net.Error.Unavailable;
    }

    sock.lock();
    defer sock.unlock();

    var sent: usize = 0;
    var cap: usize = 0;
    while (sent < data.len) {
        cap = sock.snd.wnd - (sock.snd.nxt - sock.snd.una);

        if (cap == 0) {
            trace("send: receiver window is full, waiting for ACK.", .{});
            sock.wq.wait(&sock._lock);
            continue;
        }

        const to_send = @min(sock.mss, data.len - sent, cap);
        output(sock, .ack_push, data[sent .. sent + to_send]) catch |err| {
            log.err("send: failed to send data: {t}", .{err});
            sock.state = .closed;
            return net.Error.Unavailable;
        };
        sock.snd.nxt += to_send;
        sent += to_send;
    }
}

/// Receive data from a TCP socket.
///
/// This function blocks until at least one byte of data is received.
pub fn receive(desc: usize, buf: []u8) net.Error![]u8 {
    const sock = sock_table.get(desc);
    rtt.expectEqual(.established, sock.state);

    sock.lock();
    defer sock.unlock();

    // Wait until there is data in the receive buffer.
    var remain = sock.buf.len - sock.rcv.wnd;
    while (remain == 0) : (remain = sock.buf.len - sock.rcv.wnd) {
        sock.wq.wait(&sock._lock);
    }

    // Copy data from the receive buffer to the user buffer.
    const len = @min(buf.len, remain);
    @memcpy(buf[0..len], sock.buf[0..len]);
    @memmove(sock.buf[0 .. sock.buf.len - len], sock.buf[len..]);
    sock.rcv.wnd += @intCast(len);

    return buf[0..len];
}

/// Range of dynamic TCP ports that can be used for automatic local port assignment.
const dynamic_port = common.Range{
    .start = 49152,
    .end = 65535,
};

/// Select an available dynamic port for automatic local port assignment.
fn selectDynamicPort() Port {
    for (dynamic_port.start..dynamic_port.end) |port| {
        _ = sock_table.select(.{ .ip = .any, .port = @intCast(port) }, .empty) orelse {
            return @intCast(port);
        };
    } else @panic("TCP dynamic port exhaustion");
}

// =============================================================
// Socket Internal

/// Socket table instance.
var sock_table = SocketTable{};

const SocketTable = struct {
    const Self = @This();

    /// Socket table.
    sockets: [max_sockets]Socket = [_]Socket{std.mem.zeroInit(Socket, .{
        .state = State.free,
        .local = Endpoint.empty,
        .remote = Endpoint.empty,
    })} ** max_sockets,

    /// Lock to protect a socket table.
    lock: SpinLock = .{},

    /// Maximum number of sockets to be open at the same time.
    const max_sockets = 10;

    /// Size of the receive buffer for each socket in bytes.
    const buf_size = 65335;

    /// Find a free socket to open.
    fn allocate(self: *Self) net.Error!*Socket {
        const ie = self.lock.lockDisableIrq();
        defer self.lock.unlockRestoreIrq(ie);

        for (&self.sockets) |*s| {
            if (s.state == .free) {
                s.* = std.mem.zeroInit(Socket, .{
                    .state = .closed,
                    .buf = try urd.mem.getGeneralAllocator().alloc(u8, buf_size),
                });

                return s;
            }
        } else return net.Error.OutOfMemory;
    }

    /// Release a socket.
    ///
    /// If a thread is waiting for the socket, wake it up.
    fn release(_: *Self, socket: *Socket) void {
        const allocator = urd.mem.getGeneralAllocator();

        // Notify the waiting thread if any to unblock it.
        _ = socket.wq.wake();

        // Free the queue.
        var cur = socket.rq.first;
        while (cur) |node| : (cur = node.next) {
            const entry: *const RetransmitEntry = @fieldParentPtr("_node", node);
            allocator.free(entry.data);
            allocator.destroy(entry);
        }

        // Free the receive buffer.
        allocator.free(socket.buf);

        // Invalidate the socket.
        socket.* = std.mem.zeroInit(Socket, .{
            .state = .free,
        });
    }

    /// Get a socket by its descriptor.
    fn get(self: *Self, desc: usize) *Socket {
        rtt.expect(desc < max_sockets);
        return &self.sockets[desc];
    }

    /// Select a socket matching the given local and remote endpoints.
    fn select(self: *Self, local: Endpoint, remote: Endpoint) ?*Socket {
        const ie = self.lock.lockDisableIrq();
        defer self.lock.unlockRestoreIrq(ie);

        var cand: ?*Socket = null;
        for (&self.sockets) |*s| {
            if (s.state == .free) continue;

            const local_match =
                s.local.port == local.port and
                (s.local.ip.eql(local.ip) or s.local.ip.eql(.any) or local.ip.eql(.any));
            const remote_match =
                remote.eql(s.remote) or
                s.remote.eql(.empty) or
                remote.eql(.empty);
            if (local_match and remote_match) {
                if (s.state != .listen) {
                    return s;
                } else {
                    cand = s;
                }
            }
        } else return cand;
    }

    /// Get the index of the given socket in the table.
    fn indexOf(self: *Self, socket: *const Socket) usize {
        const index = (@intFromPtr(socket) - @intFromPtr(&self.sockets)) / @sizeOf(Socket);
        rtt.expect(index < self.sockets.len);
        return index;
    }
};

/// Get a random number generator instance.
fn rng() std.Random {
    const Prng = std.Random.DefaultPrng;
    const instance = struct {
        var prng: ?Prng = null;
        var lock: SpinLock = .{};
    };

    const ie = instance.lock.lockDisableIrq();
    defer instance.lock.unlockRestoreIrq(ie);

    if (instance.prng == null) {
        var seed: [@sizeOf(u64)]u8 = undefined;
        urd.rng.getRandom(&seed);
        instance.prng = Prng.init(@bitCast(seed));
    }

    return instance.prng.?.random();
}

const Socket = struct {
    /// Connection state.
    state: State,
    /// Local endpoint.
    local: Endpoint,
    /// Remote endpoint.
    remote: Endpoint,

    /// SND var.
    snd: Snd,
    /// Initial send sequence number.
    iss: u32,
    /// RCV var.
    rcv: Rcv,
    /// Initial receive sequence number.
    irs: u32,
    /// Max segment size.
    mss: u16,

    /// Receive buffer.
    buf: []u8,

    /// Retransmission queue.
    rq: std.DoublyLinkedList,
    /// Wait queue.
    wq: urd.WaitQueue,
    /// Lock to protect the wait queue.
    _lock: SpinLock,
    _lock_ie: u64,

    pub fn wait(self: *Socket) void {
        rtt.expect(self.state != .free);

        const ie = self._lock.lockDisableIrq();
        defer self._lock.unlockRestoreIrq(ie);

        self.wq.wait(&self._lock);
    }

    pub fn wake(self: *Socket) void {
        rtt.expect(self.state != .free);

        const ie = self._lock.lockDisableIrq();
        defer self._lock.unlockRestoreIrq(ie);

        _ = self.wq.wake();
    }

    pub fn lock(self: *Socket) void {
        rtt.expect(self.state != .free);
        self._lock_ie = self._lock.lockDisableIrq();
    }

    pub fn unlock(self: *Socket) void {
        rtt.expect(self.state != .free);
        self._lock.unlockRestoreIrq(self._lock_ie);
    }

    /// Push the segment to the retransmission queue.
    pub fn rtpush(self: *Socket, seq: u32, flags: Flags, data: []const u8) Allocator.Error!void {
        const allocator = urd.mem.getGeneralAllocator();
        const entry = try allocator.create(RetransmitEntry);
        errdefer allocator.destroy(entry);

        const buf = try allocator.alloc(u8, data.len);
        errdefer allocator.free(buf);
        @memcpy(buf, data);

        const timestamp = urd.time.getCurrentTimestamp();
        entry.* = .{
            .time_first = timestamp,
            .time_last = timestamp,
            .rto = default_rto,
            .seq = seq,
            .flags = flags,
            .data = buf,
        };
        self.rq.append(&entry._node);
    }

    /// Clean up all entries in the retransmission queue that have been acknowledged.
    pub fn rtclean(self: *Socket) void {
        var cur = self.rq.first;
        while (cur) |node| : (cur = node.next) {
            const entry: *const RetransmitEntry = @fieldParentPtr("_node", node);

            var consume = entry.data.len;
            if (entry.flags.syn or entry.flags.fin) {
                consume += 1;
            }
            if (self.snd.una < entry.seq + consume) {
                break;
            }

            const allocator = urd.mem.getGeneralAllocator();
            self.rq.remove(node);
            allocator.free(entry.data);
            allocator.destroy(entry);
        }
    }
};

/// Default retransmission timeout in microseconds.
const default_rto = 200 * std.time.us_per_s;
/// Interval for checking retransmission timeouts in microseconds.
const retransmit_interval_us = 10 * std.time.us_per_s;
/// Maximum number of seconds to keep an unacknowledged segment in the retransmission queue.
const retransmit_deadline_sec = 12;

const RetransmitEntry = struct {
    /// Timestamp of the first transmission of the segment.
    time_first: urd.time.Ktimestamp,
    /// Timestamp of the most recent transmission of the segment.
    time_last: urd.time.Ktimestamp,
    /// Retransmission timeout in microseconds.
    rto: u64,
    /// Sequence number of the segment.
    seq: u32,
    /// Flags of the segment.
    flags: Flags,
    /// Data of the segment.
    data: []const u8,
    /// List head.
    _node: std.DoublyLinkedList.Node = .{},
};

/// Called periodically to check retransmission queue.
fn timerFn() void {
    for (&sock_table.sockets) |*sock| {
        if (sock.state == .free) continue;

        var cur = sock.rq.first;
        while (cur) |node| : (cur = node.next) {
            const entry: *RetransmitEntry = @fieldParentPtr("_node", node);
            const timestamp = urd.time.getCurrentTimestamp();
            const elapsed = timestamp - entry.time_last;

            if (timestamp - entry.time_first > retransmit_deadline_sec * std.time.us_per_s) {
                sock.state = .closed;
                sock.wake();
                continue;
            }

            if (elapsed >= entry.rto) {
                outputSegment(
                    sock.local,
                    sock.remote,
                    entry.seq,
                    sock.rcv.nxt,
                    sock.rcv.wnd,
                    entry.flags,
                    entry.data,
                ) catch {};

                // Exponential backoff.
                entry.time_last = timestamp;
                entry.rto = @min(entry.rto * 2, 60 * std.time.us_per_s);
            }
        }
    }
}

const State = enum {
    /// Socket is not in use.
    free,
    /// Connection is not yet established or has been closed.
    closed,
    /// Waiting for a connection request from the remote host.
    listen,
    /// Waiting for a matching connection request after having sent a connection request.
    syn_sent,
    /// Waiting for a confirming connection request acknowledgment after having both sent and received a connection request.
    syn_received,
    /// Connection is established.
    established,
    /// Waiting for a connection termination request from the remote host.
    fin_wait1,
    /// Waiting for a connection termination request from the remote host after having sent a connection termination request.
    fin_wait2,
    /// Waiting for a connection termination request from the local host.
    close_wait,
    /// Waiting for a connection termination request from both the local and remote host.
    closing,
    /// Waiting for a final acknowledgment after having sent a connection termination request.
    last_ack,
    /// Waiting for a timeout after having closed the connection.
    time_wait,
};

/// SND variable to manage the sending side of a TCP connection.
const Snd = struct {
    /// The next sequence number to be sent.
    nxt: u32,
    /// The leftmost sequence number of the unacknowledged data.
    una: u32,
    /// Send window (the number of bytes that can be sent without acknowledgment).
    wnd: u16,
    /// The last sequence number sent in a window update.
    wl1: u32,
    /// The last sequence number sent in an acknowledgment.
    wl2: u32,
};

/// RCV variable to manage the receiving side of a TCP connection.
const Rcv = struct {
    /// The next sequence number expected on an incoming segment.
    nxt: u32,
    /// Receive window.
    wnd: u16,
};

/// SEG variable to manage a TCP segment being processed.
const Seg = struct {
    /// Sequence number of the first data byte in the segment.
    seq: u32,
    /// Acknowledgment number.
    ack: u32,
    /// Window size.
    wnd: u16,
    /// Length of the segment's data in bytes.
    len: usize,
};

// =============================================================
// Data structures
// =============================================================

/// Port number type.
const Port = u16;

/// TCP header.
const Header = extern struct {
    /// Source port.
    src: Port,
    /// Destination port.
    dst: Port,
    /// Sequence number.
    seq: u32,
    /// Acknowledgment number.
    ack: u32,
    /// Data offset.
    offset: u8,
    /// Flags.
    flags: Flags,
    /// Window size.
    window: u16,
    /// Checksum.
    checksum: u16,
    /// Urgent pointer.
    urgent: u16,
};

const Flags = packed struct(u8) {
    /// FIN: No more data from sender.
    fin: bool,
    /// SYN: Synchronize sequence numbers.
    syn: bool,
    /// RST: Reset the connection.
    rst: bool,
    /// PSH: Push function.
    psh: bool,
    /// ACK: Acknowledgment field is significant.
    ack: bool,
    /// URG: Urgent pointer field is significant.
    urg: bool,
    /// Reserved.
    _rsvd: u2 = 0,

    const sync = std.mem.zeroInit(Flags, .{
        .syn = true,
    });
    const sync_ack = std.mem.zeroInit(Flags, .{
        .syn = true,
        .ack = true,
    });
    const reset = std.mem.zeroInit(Flags, .{
        .rst = true,
    });
    const reset_ack = std.mem.zeroInit(Flags, .{
        .rst = true,
        .ack = true,
    });
    const ackn = std.mem.zeroInit(Flags, .{
        .ack = true,
    });
    const ack_push = std.mem.zeroInit(Flags, .{
        .ack = true,
        .psh = true,
    });

    pub fn format(self: Flags, writer: *std.Io.Writer) !void {
        var buf: [6]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{s}{s}{s}{s}{s}{s}", .{
            if (self.fin) "F" else ".",
            if (self.syn) "S" else ".",
            if (self.rst) "R" else ".",
            if (self.psh) "P" else ".",
            if (self.ack) "A" else ".",
            if (self.urg) "U" else ".",
        }) catch unreachable;
        try writer.writeAll(s);
    }
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
    /// Length of the TCP header and payload in bytes.
    length: u16,
};

// =============================================================
// Debug
// =============================================================

fn print(data: []const u8, logger: anytype) void {
    const io = net.util.WireReader(Header).new(data);

    logger("TCP: {d} -> {d}, seq={d}, ack={d}, flags=[{f}]", .{
        io.read(.src),
        io.read(.dst),
        io.read(.seq),
        io.read(.ack),
        io.read(.flags),
    });
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.tcp);
const trace = urd.trace.scoped(.net, .tcp);
const Allocator = std.mem.Allocator;
const common = @import("common");
const rtt = common.rtt;
const urd = @import("urthr");
const SpinLock = urd.SpinLock;
const net = urd.net;
const IpAddr = net.ip.IpAddr;
