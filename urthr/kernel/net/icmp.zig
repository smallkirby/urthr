//! ICMP: Internet Control Message Protocol.

pub const vtable = net.ip.Protocol.Vtable{
    .input = inputImpl,
};

/// Handle an incoming ICMP packet.
fn inputImpl(_: net.ip.HeaderReader, data: []const u8) net.Error!void {
    if (data.len < @sizeOf(Header)) {
        log.warn("Too small ICMP packet size: {d}", .{data.len});
        return net.Error.InvalidPacket;
    }

    if (nutil.calcChecksum(data) != 0) {
        log.warn("Invalid ICMP checksum", .{});
        return net.Error.InvalidPacket;
    }

    print(data, log.debug);
}

/// ICMP message types.
const MessageType = enum(u8) {
    /// Echo Reply.
    echo_reply = 0,
    /// Destination Unreachable.
    dest_unreachable = 3,
    /// Source Quench.
    source_quench = 4,
    /// Redirect.
    redirect = 5,
    /// Echo Request.
    echo = 8,
    /// Time Exceeded.
    time_exceeded = 11,
    /// Timestamp.
    timestamp = 13,
    /// Timestamp Reply.
    timestamp_reply = 14,
    /// Information Request.
    info_request = 15,
    /// Information Reply.
    info_reply = 16,

    _,

    /// Get the string representation of the message type.
    pub fn str(self: MessageType) []const u8 {
        return switch (self) {
            else => @tagName(self),
            _ => "unknown",
        };
    }
};

/// ICMP header.
const Header = extern struct {
    /// Message type.
    type: MessageType,
    /// Code for the message type.
    code: u8,
    /// Checksum.
    checksum: u16,

    comptime {
        urd.comptimeAssert(@sizeOf(Header) == 4, null, .{});
    }
};

// =============================================================
// Message Types
// =============================================================

/// ICMP Echo / Echo Reply message.
const EchoData = extern struct {
    /// Common header.
    hdr: Header,
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
    const io = net.WireReader(Header).new(data);
    const typ = io.read(.type);

    logger("ICMP packet: size={d}", .{data.len});
    logger("  type: {s} ({d})", .{ typ.str(), typ });
    logger("  code: {d}", .{io.read(.code)});
    logger("  sum : 0x{X:0>4}", .{io.read(.checksum)});

    switch (typ) {
        .echo, .echo_reply => {
            const sio = net.WireReader(EchoData).new(data);
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
