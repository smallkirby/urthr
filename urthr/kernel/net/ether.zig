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
    fn print(self: MacAddr, buf: []u8) std.fmt.BufPrintError![]u8 {
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

    /// Custom formatter.
    pub fn format(self: MacAddr, writer: *std.Io.Writer) !void {
        var buf: [MacAddr.string_length + 1]u8 = undefined;
        const s = self.print(&buf) catch "<invalid>";
        try writer.writeAll(s);
    }

    /// Check equality with another MAC address.
    pub fn eql(self: MacAddr, other: MacAddr) bool {
        return std.meta.eql(self.value, other.value);
    }

    /// Create a MAC address from the given byte slice.
    pub fn from(value: []const u8) MacAddr {
        var bytes: [length]u8 = undefined;
        @memcpy(&bytes, value);
        return MacAddr{ .value = bytes };
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
    type: net.Protocol,
};

/// Input Ethernet frame data.
pub fn inputFrame(dev: *net.Device, data: []const u8) void {
    const io = net.WireReader(EtherHeader).new(data);
    const header: *align(1) const EtherHeader = @ptrCast(data.ptr);

    // Check if the frame is destined to this device.
    const addr = MacAddr.from(dev.addr[0..MacAddr.length]);
    const is_broadcast = header.dest.eql(.broadcast);
    const is_bound_me = header.dest.eql(addr);
    if (!is_broadcast and !is_bound_me) {
        return;
    }

    // Process the input frame.
    net.handleInput(
        dev,
        io.read(.type),
        data[@sizeOf(EtherHeader)..],
    ) catch {};
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const urd = @import("urthr");
const net = urd.net;
