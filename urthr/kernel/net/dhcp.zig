//! Light-weight DHCP client.
//!
//! ref. https://datatracker.ietf.org/doc/html/rfc2131

/// DHCP query result.
const QueryResult = struct {
    /// Your IP address offered by the server.
    yip: IpAddr,
    /// Server IP address.
    server: IpAddr,
    /// Subnet mask.
    subnet_mask: IpAddr,
    /// Default gateway.
    router: IpAddr,
    /// DNS server.
    dns: IpAddr,
};

/// Query the DHCP server to acquire an IP address and other network configuration parameters.
///
/// This function blocks until the handshake is complete or an error occurs.
pub fn query(iface: *const net.Interface) net.Error!QueryResult {
    // Set up UDP socket.
    var recvbuf: [512]u8 = undefined;
    const sock = try udp.open();
    defer udp.close(sock);
    try udp.bind(sock, .{ .ip = .any, .port = client_port });

    // Allocate a DHCP transaction entry.
    const entry = QueryEntry{
        .hwaddr = iface.device.?.getAddr(),
        .xid = generateXid(),
    };

    // DHCPDISCOVER
    try discover(sock, &entry);

    // Receive DHCPOFFER message.
    const offer = udp.recvfrom(sock, &recvbuf);
    const result = try parseOffer(offer.data, &entry);
    trace("Server offered: {f}, subnet={f}, router={f}, dns={f}", .{ result.yip, result.subnet_mask, result.router, result.dns });

    // DHCPREQUEST
    try request(sock, &entry, result);

    // Receive DHCPACK message.
    const ack = udp.recvfrom(sock, &recvbuf);
    try validateAck(ack.data, &entry);

    return result;
}

/// Send DHCPDISCOVER message on all interfaces to acquire an IP address.
fn discover(sock: usize, entry: *const QueryEntry) net.Error!void {
    // Allocate a buffer.
    var nbuf = try net.NetBuffer.init(512, urd.mem.getGeneralAllocator());
    defer nbuf.deinit();
    nbuf.reserve(@sizeOf(Message));

    // Construct DHCPDISCOVER message.
    var opts = OptionWriter.init(&nbuf);
    try opts.write(.{
        .message_type = .discover,
    });
    try opts.write(.{
        .request_list = .{ .codes = &[_]Parameter{ .subnet_mask, .router, .dns } },
    });
    try opts.finalize();

    // Construct message header.
    const msgp = try nbuf.prepend(@sizeOf(Message));
    const msg = net.util.WireWriter(Message).new(msgp);
    msg.write(.op, .request);
    msg.write(.htype, 1); // TODO: Ethernet
    msg.write(.hlen, @intCast(entry.hwaddr.len));
    msg.write(.hops, 0);
    msg.write(.xid, entry.xid);
    msg.write(.secs, 0);
    msg.write(.flags, .{ .broadcast = true });
    msg.write(.ciaddr, .any);
    msg.write(.yiaddr, .any);
    msg.write(.siaddr, .any);
    msg.write(.giaddr, .any);
    msg.clear(.chaddr);
    @memcpy(msg.slice(.chaddr)[0..entry.hwaddr.len], entry.hwaddr);
    msg.clear(.sname);
    msg.clear(.file);

    // Send the message to the broadcast address.
    try udp.sendto(sock, nbuf.data(), .{
        .ip = .limited_broadcast,
        .port = server_port,
    });
}

/// Send DHCPREQUEST message to request the offered IP address.
fn request(sock: usize, entry: *const QueryEntry, offer: QueryResult) net.Error!void {
    // Allocate a buffer.
    var nbuf = try net.NetBuffer.init(512, urd.mem.getGeneralAllocator());
    defer nbuf.deinit();
    nbuf.reserve(@sizeOf(Message));

    // Construct DHCPREQUEST message.
    var opts = OptionWriter.init(&nbuf);
    try opts.write(.{
        .message_type = .request,
    });
    try opts.write(.{
        .request_ip = .{ .ip = offer.yip },
    });
    try opts.write(.{
        .server_id = .{ .ip = offer.server },
    });
    try opts.finalize();

    // Construct message header.
    const msgp = try nbuf.prepend(@sizeOf(Message));
    const msg = net.util.WireWriter(Message).new(msgp);
    msg.write(.op, .request);
    msg.write(.htype, 1); // TODO: Ethernet
    msg.write(.hlen, @intCast(entry.hwaddr.len));
    msg.write(.hops, 0);
    msg.write(.xid, entry.xid);
    msg.write(.secs, 0);
    msg.write(.flags, .{ .broadcast = true });
    msg.write(.ciaddr, .any);
    msg.write(.yiaddr, .any);
    msg.write(.siaddr, .any);
    msg.write(.giaddr, .any);
    msg.clear(.chaddr);
    @memcpy(msg.slice(.chaddr)[0..entry.hwaddr.len], entry.hwaddr);
    msg.clear(.sname);
    msg.clear(.file);

    // Send the message to the broadcast address.
    try udp.sendto(sock, nbuf.data(), .{
        .ip = .limited_broadcast,
        .port = server_port,
    });
}

/// Parse DHCPOFFER message.
fn parseOffer(buf: []const u8, entry: *const QueryEntry) net.Error!QueryResult {
    const hdr = net.util.WireReader(Message).new(buf);

    // Validate the message.
    if (buf.len < @sizeOf(Message)) {
        log.err("Too small DHCP message: {d}", .{buf.len});
        return net.Error.InvalidPacket;
    }
    if (hdr.read(.op) != .reply) {
        log.err("Invalid DHCP message op: {d}", .{hdr.read(.op)});
        return net.Error.InvalidPacket;
    }
    if (hdr.read(.htype) != 1) {
        log.err("Unsupported hardware type: {d}", .{hdr.read(.htype)});
        return net.Error.InvalidPacket;
    }
    if (hdr.read(.hlen) != entry.hwaddr.len) {
        log.err("Invalid hardware address length: {d}", .{hdr.read(.hlen)});
        return net.Error.InvalidPacket;
    }
    if (hdr.read(.xid) != entry.xid) {
        log.err("Transaction ID mismatch: {X}", .{hdr.read(.xid)});
        return net.Error.InvalidPacket;
    }
    const hwaddr = hdr.slice(.chaddr)[0..hdr.read(.hlen)];
    if (!std.mem.eql(u8, hwaddr, entry.hwaddr)) {
        log.err("Hardware address mismatch.", .{});
        return net.Error.InvalidPacket;
    }

    // Parse options.
    var options = OptionReader.init(buf);
    var server: ?IpAddr = null;
    var subnet_mask: ?IpAddr = null;
    var router: ?IpAddr = null;
    var dns: ?IpAddr = null;
    while (options.next()) |opt| {
        switch (opt.code) {
            .message_type => if (opt.data.len != 1 or opt.data[0] != 2) {
                log.err("Invalid DHCP message type: {d}", .{opt.data[0]});
                return net.Error.InvalidPacket;
            },

            .server_id => if (opt.data.len != 4) {
                log.err("Invalid server_id option length: {d}", .{opt.data.len});
                return net.Error.InvalidPacket;
            } else {
                server = @bitCast(IpAddr.from(opt.data[0..4]));
            },

            .subnet_mask => if (opt.data.len != 4) {
                log.err("Invalid subnet_mask option length: {d}", .{opt.data.len});
                return net.Error.InvalidPacket;
            } else {
                subnet_mask = @bitCast(IpAddr.from(opt.data[0..4]));
            },

            .router => if (opt.data.len != 4) {
                log.err("Invalid router option length: {d}", .{opt.data.len});
                return net.Error.InvalidPacket;
            } else {
                router = @bitCast(IpAddr.from(opt.data[0..4]));
            },

            .dns => if (opt.data.len != 4) {
                log.err("Invalid dns option length: {d}", .{opt.data.len});
                return net.Error.InvalidPacket;
            } else {
                dns = @bitCast(IpAddr.from(opt.data[0..4]));
            },

            else => {},
        }
    }

    return QueryResult{
        .yip = hdr.read(.yiaddr),
        .server = server.?,
        .subnet_mask = subnet_mask.?,
        .router = router.?,
        .dns = dns.?,
    };
}

/// Parse to validate DHCPACK message.
fn validateAck(buf: []const u8, entry: *const QueryEntry) net.Error!void {
    const hdr = net.util.WireReader(Message).new(buf);

    // Validate the message.
    if (buf.len < @sizeOf(Message)) {
        log.err("Too small DHCP message: {d}", .{buf.len});
        return net.Error.InvalidPacket;
    }
    if (hdr.read(.op) != .reply) {
        log.err("Invalid DHCP message op: {d}", .{hdr.read(.op)});
        return net.Error.InvalidPacket;
    }
    if (hdr.read(.htype) != 1) {
        log.err("Unsupported hardware type: {d}", .{hdr.read(.htype)});
        return net.Error.InvalidPacket;
    }
    if (hdr.read(.hlen) != entry.hwaddr.len) {
        log.err("Invalid hardware address length: {d}", .{hdr.read(.hlen)});
        return net.Error.InvalidPacket;
    }
    if (hdr.read(.xid) != entry.xid) {
        log.err("Transaction ID mismatch: {X}", .{hdr.read(.xid)});
        return net.Error.InvalidPacket;
    }
    const hwaddr = hdr.slice(.chaddr)[0..hdr.read(.hlen)];
    if (!std.mem.eql(u8, hwaddr, entry.hwaddr)) {
        log.err("Hardware address mismatch.", .{});
        return net.Error.InvalidPacket;
    }

    // Parse options.
    var options = OptionReader.init(buf);
    while (options.next()) |opt| {
        switch (opt.code) {
            .message_type => if (opt.data.len != 1 or opt.data[0] != 5) {
                log.err("Invalid DHCP message type: {d}", .{opt.data[0]});
                return net.Error.InvalidPacket;
            } else return,

            else => {},
        }
    } else {
        log.err("Missing DHCP message type option.", .{});
        return net.Error.InvalidPacket;
    }
}

/// Generate a random transaction ID.
fn generateXid() u32 {
    // TODO: use a proper RNG.
    return 0xDEADBEEF;
}

/// Context for an ongoing DHCP transaction.
const QueryEntry = struct {
    /// Hardware address of the client.
    hwaddr: []const u8,
    /// Transaction ID.
    xid: u32,
};

// =============================================================
// Data structures
// =============================================================

/// Client UDP port for DHCP.
const client_port = 68;
/// Server UDP port for DHCP.
const server_port = 67;

/// DHCP message structure.
const Message = extern struct {
    /// Message op code.
    op: Op,
    /// Hardware address type.
    htype: u8,
    /// Hardware address length.
    hlen: u8,
    /// Client sets to zero, optionally used by relay agents.
    hops: u8,
    /// Transaction ID.
    xid: u32,
    /// Seconds elapsed since client began address acquisition or renewal process.
    secs: u16,
    /// Flags.
    flags: Flags,
    /// Client IP address.
    ciaddr: IpAddr,
    /// Your (client) IP address.
    yiaddr: IpAddr,
    /// Next server IP address.
    siaddr: IpAddr,
    /// Relay agent IP address.
    giaddr: IpAddr,
    /// Client hardware address.
    chaddr: [16]u8,
    /// Server host name, null-terminated string.
    sname: [64]u8,
    /// Boot file name, null-terminated string.
    file: [128]u8,

    // Options follow immediately after the fixed header.
};

const Op = enum(u8) {
    /// BOOTREQUEST
    request = 1,
    /// BOOTREPLY
    reply = 2,
};

const Flags = packed struct(u16) {
    /// Reserved zero.
    _0: u15 = 0,
    /// BROADCAST flag.
    broadcast: bool,
};

const Parameter = enum(u8) {
    subnet_mask = 1,
    router = 3,
    dns = 6,
};

// https://datatracker.ietf.org/doc/html/rfc1533
const Option = union(OptionEnum) {
    /// PAD.
    pad: struct {
        pub fn copy(_: @This(), _: []u8) void {}

        pub fn len(_: @This()) usize {
            return 0;
        }
    },

    /// Subnet Mask.
    subnet_mask: extern struct {
        ip: IpAddr,

        pub fn copy(self: @This(), out: []u8) void {
            @memcpy(out[0..IpAddr.length], std.mem.asBytes(&self.ip._value));
        }

        pub fn len(_: @This()) usize {
            return IpAddr.length;
        }
    },

    /// Router.
    router: extern struct {
        ip: IpAddr,

        pub fn copy(self: @This(), out: []u8) void {
            @memcpy(out[0..IpAddr.length], std.mem.asBytes(&self.ip._value));
        }

        pub fn len(_: @This()) usize {
            return IpAddr.length;
        }
    },

    /// DNS.
    dns: extern struct {
        ip: IpAddr,

        pub fn copy(self: @This(), out: []u8) void {
            @memcpy(out[0..IpAddr.length], std.mem.asBytes(&self.ip._value));
        }

        pub fn len(_: @This()) usize {
            return IpAddr.length;
        }
    },

    /// Requested IP Address.
    request_ip: extern struct {
        ip: IpAddr,

        pub fn copy(self: @This(), out: []u8) void {
            @memcpy(out[0..IpAddr.length], std.mem.asBytes(&self.ip._value));
        }

        pub fn len(_: @This()) usize {
            return IpAddr.length;
        }
    },

    /// Message Type.
    message_type: enum(u8) {
        /// DHCPDISCOVER
        discover = 1,
        /// DHCPOFFER
        offer = 2,
        /// DHCPREQUEST
        request = 3,

        pub fn copy(self: @This(), out: []u8) void {
            out[0] = @intFromEnum(self);
        }

        pub fn len(_: @This()) usize {
            return 1;
        }
    },

    /// Served Identifier.
    server_id: extern struct {
        ip: IpAddr,

        pub fn copy(self: @This(), out: []u8) void {
            @memcpy(out[0..IpAddr.length], std.mem.asBytes(&self.ip._value));
        }

        pub fn len(_: @This()) usize {
            return IpAddr.length;
        }
    },

    /// Parameter Request List.
    request_list: struct {
        /// List of requested option codes.
        codes: []const Parameter,

        pub fn copy(self: @This(), out: []u8) void {
            const p: [*]const u8 = @ptrCast(self.codes.ptr);
            @memcpy(out[0..self.codes.len], p[0..self.codes.len]);
        }

        pub fn len(self: @This()) usize {
            return self.codes.len;
        }
    },

    /// END
    end: struct {
        pub fn copy(_: @This(), _: []u8) void {}

        pub fn len(_: @This()) usize {
            return 0;
        }
    },
};

const OptionEnum = enum(u8) {
    pad = 0,
    subnet_mask = 1,
    router = 3,
    dns = 6,
    request_ip = 50,
    message_type = 53,
    server_id = 54,
    request_list = 55,
    end = 255,
    _,
};

const OptionWriter = struct {
    const Self = @This();

    nbuf: *net.NetBuffer,

    pub fn init(nbuf: *net.NetBuffer) Self {
        return .{
            .nbuf = nbuf,
        };
    }

    pub fn write(self: *Self, code: Option) net.Error!void {
        switch (code) {
            inline else => |c| {
                const opt = try self.nbuf.append(2 + c.len());
                opt[0] = @intFromEnum(code);
                opt[1] = @intCast(c.len());
                c.copy(opt[2..]);
            },
        }
    }

    pub fn finalize(self: *Self) net.Error!void {
        // Append END option.
        const opt = try self.nbuf.append(1);
        opt[0] = @intFromEnum(Option.end);

        // Prepend cookie.
        const cookie = try self.nbuf.prepend(4);
        cookie[0] = 0x63;
        cookie[1] = 0x82;
        cookie[2] = 0x53;
        cookie[3] = 0x63;
    }
};

const OptionReader = struct {
    const Self = @This();

    data: []const u8,
    cur: []const u8,

    pub fn init(data: []const u8) Self {
        // Seek until the magic cookie.
        var i: usize = 0;
        while (i + 4 <= data.len) : (i += 1) {
            if (isCookie(data[i..])) {
                i += 4;
                break;
            }
        } else i = data.len;

        return .{
            .data = data[i..],
            .cur = data[i..],
        };
    }

    pub const RawEntry = struct {
        code: OptionEnum,
        data: []const u8,
    };

    fn isCookie(data: []const u8) bool {
        if (data.len < 4) return false;
        return std.mem.eql(u8, data[0..4], &[_]u8{ 0x63, 0x82, 0x53, 0x63 });
    }

    pub fn next(self: *Self) ?RawEntry {
        if (self.cur.len == 0) {
            return null;
        }

        const code = self.cur[0];
        if (code == @intFromEnum(Option.end)) {
            return null;
        }
        if (code == @intFromEnum(Option.pad)) {
            self.cur = self.cur[1..];
            return self.next();
        }

        const len = self.cur[1];
        if (self.cur.len < 2 + len) {
            log.err("Invalid DHCP option: insufficient length for code {d}", .{code});
            return null;
        }

        const data = self.cur[2 .. 2 + len];
        self.cur = self.cur[2 + len ..];

        return .{
            .code = @enumFromInt(code),
            .data = data,
        };
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.dhcp);
const trace = urd.trace.scoped(.net, .dhcp);
const common = @import("common");
const urd = @import("urthr");
const SpinLock = urd.SpinLock;
const net = urd.net;
const udp = net.udp;
const IpAddr = net.ip.IpAddr;
