//! ICMP: Internet Control Message Protocol.
//!
//! ref. https://datatracker.ietf.org/doc/html/rfc792

pub const vtable = net.ip.Protocol.Vtable{
    .input = inputImpl,
};

/// Handle an incoming ICMP packet.
fn inputImpl(hdr: net.ip.HeaderReader, data: []const u8) net.Error!void {
    const io = net.WireReader(HeaderCommon).new(data);

    if (data.len < @sizeOf(HeaderCommon)) {
        log.warn("Too small ICMP packet: {d}", .{data.len});
        return net.Error.InvalidPacket;
    }

    if (nutil.calcChecksum(data) != 0) {
        log.warn("Invalid ICMP checksum", .{});
        return net.Error.InvalidPacket;
    }

    print(data, log.debug);

    switch (io.read(.type)) {
        .echo => {
            const sio = net.WireReader(EchoHeader).new(data);
            try output(
                hdr.read(.dest_addr),
                hdr.read(.src_addr),
                .{ .echo_reply = .{
                    .id = sio.read(.id),
                    .sequence = sio.read(.sequence),
                    .data = data[@sizeOf(EchoHeader)..],
                } },
            );
        },
        else => {},
    }
}

/// Send an ICMP message.
pub fn output(src: net.ip.IpAddr, dest: net.ip.IpAddr, msg: Message) net.Error!void {
    var nbuf = try NetBuffer.init(
        msg.len(),
        urd.mem.getGeneralAllocator(),
    );
    defer nbuf.deinit();

    const buf = try nbuf.append(msg.len());
    msg.fill(buf);

    try net.ip.output(src, dest, .icmp, &nbuf);
}

/// ICMP messages.
///
/// This struct describes the messages of each type.
/// Users do not have to care about the byte layout of the messages.
pub const Message = union(MessageType) {
    /// ICMP Echo Reply.
    echo_reply: Echo,
    /// ICMP Echo Request.
    echo: Echo,

    pub const Echo = struct {
        /// ID to aid in matching requests and replies.
        id: u16,
        /// Sequence number to aid in matching echos and replies.
        sequence: u16,
        /// Payload data of arbitrary content.
        data: []const u8,
    };

    /// Get the length of the message including header and payload.
    fn len(self: Message) usize {
        return switch (self) {
            .echo, .echo_reply => |echo| @sizeOf(EchoHeader) + echo.data.len,
        };
    }

    /// Get the message code of the message.
    fn code(self: Message) u8 {
        return switch (self) {
            .echo, .echo_reply => 0,
        };
    }

    /// Get the payload data of the message.
    fn data(self: Message) []const u8 {
        return switch (self) {
            .echo, .echo_reply => |echo| echo.data,
        };
    }

    /// Get the type of the message.
    fn typ(self: Message) MessageType {
        return @enumFromInt(@intFromEnum(self));
    }

    /// Fill the given buffer with the message content.
    fn fill(self: Message, buf: []u8) void {
        const io = net.WireWriter(HeaderCommon).new(buf);

        // Fill the common fields.
        io.write(.type, self.typ());
        io.write(.code, self.code());
        io.write(.checksum, 0);
        @memcpy(buf[@sizeOf(VoidHeader)..], self.data());

        // Fill the message-specific fields.
        switch (self) {
            .echo, .echo_reply => |echo| {
                const sio = net.WireWriter(EchoHeader).new(buf);
                sio.write(.id, echo.id);
                sio.write(.sequence, echo.sequence);
            },
        }

        // Calculate and fill the checksum.
        io.write(.checksum, nutil.calcChecksum(buf[0..self.len()]));
    }
};

// =============================================================
// Data structures
// =============================================================

/// ICMP message types.
const MessageType = enum(u8) {
    /// Echo Reply.
    echo_reply = 0,
    /// Echo Request.
    echo = 8,

    _,

    /// Get the string representation of the message type.
    pub fn str(self: MessageType) []const u8 {
        return switch (self) {
            else => @tagName(self),
            _ => "unknown",
        };
    }
};

/// ICMP header common part.
const HeaderCommon = extern struct {
    /// Message type.
    type: MessageType,
    /// Code for the message type.
    code: u8,
    /// Checksum.
    checksum: u16,

    // Message-specific data follows.

    comptime {
        urd.comptimeAssert(@sizeOf(HeaderCommon) == 4, null, .{});
    }
};

/// Type-erased ICMP header.
const VoidHeader = extern struct {
    /// Common header.
    hdr: HeaderCommon,
    /// Message-specific data.
    specific: u32,
};

/// ICMP Echo / Echo Reply message.
const EchoHeader = extern struct {
    /// Common header.
    hdr: HeaderCommon,
    /// Identifier.
    id: u16,
    /// Sequence Number.
    sequence: u16,
};

// =============================================================
// Debug
// =============================================================

/// Debug print the given ICMP packet.
fn print(data: []const u8, logger: anytype) void {
    const io = net.WireReader(HeaderCommon).new(data);
    const typ = io.read(.type);

    logger("ICMP packet: size={d}", .{data.len});
    logger("  type: {s} ({d})", .{ typ.str(), typ });
    logger("  code: {d}", .{io.read(.code)});
    logger("  sum : 0x{X:0>4}", .{io.read(.checksum)});

    switch (typ) {
        .echo, .echo_reply => {
            const sio = net.WireReader(EchoHeader).new(data);
            logger("  id  : {d}", .{sio.read(.id)});
            logger("  seq : {d}", .{sio.read(.sequence)});
        },
        else => {},
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.icmp);
const urd = @import("urthr");
const net = urd.net;
const nutil = @import("nutil.zig");
const NetBuffer = @import("NetBuffer.zig");
