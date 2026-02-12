//! Ethernet protocol implementation.

/// MAC Address type.
pub const MacAddr = extern struct {
    /// Length in bytes of MAC address.
    pub const length = 6;
    /// Maximum length of string representation of MAC address.
    pub const string_length = 17;

    /// Internal byte array representation.
    value: [length]u8,

    /// Broadcast MAC address.
    pub const broadcast = MacAddr{
        .value = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF },
    };

    /// Empty invalid MAC address.
    pub const empty = MacAddr{
        .value = [_]u8{ 0, 0, 0, 0, 0, 0 },
    };

    /// Print the MAC address into the given buffer.
    pub fn print(self: MacAddr, buf: []u8) std.fmt.BufPrintError![]u8 {
        return std.fmt.bufPrint(
            buf,
            "{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}",
            .{
                self.value[0],
                self.value[1],
                self.value[2],
                self.value[3],
                self.value[4],
                self.value[5],
            },
        );
    }
};

/// Ethernet frame header.
///
/// Assuming no preamble and FCS.
const EtherHeader = extern struct {
    /// Destination MAC address.
    dest: MacAddr,
    /// Source MAC address.
    src: MacAddr,
    /// EtherType.
    type: EtherType,
};

/// Ethernet frame EtherType.
const EtherType = enum(u16) {
    /// IPv4
    ip = 0x0800,
    /// ARP
    arp = 0x0806,
};

/// Input Ethernet frame data.
pub fn inputFrame(dev: *net.Device, data: []const u8) void {
    const io = net.WireReader(EtherHeader).new(data);

    const is_broadcast = std.mem.eql(u8, MacAddr.broadcast.value[0..], io.read(.dest).value[0..]);
    const is_bound_me = std.mem.eql(u8, dev.addr[0..MacAddr.length], io.read(.dest).value[0..]);
    if (!is_broadcast and !is_bound_me) {
        return;
    }

    net.handleInput(
        dev,
        @enumFromInt(@intFromEnum(io.read(.type))),
        data[@sizeOf(EtherHeader)..],
    ) catch {};
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.ether);
const Allocator = std.mem.Allocator;
const common = @import("common");
const bits = common.bits;
const util = common.util;
const urd = @import("urthr");
const net = urd.net;
const Interface = net.Interface;
