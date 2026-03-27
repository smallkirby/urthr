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
        @memcpy(&bytes, value[0..length]);
        return MacAddr{ .value = bytes };
    }

    /// Encode a MAC address from the given string.
    pub fn encode(comptime s: []const u8) MacAddr {
        var bytes: [length]u8 = undefined;
        var parts = std.mem.splitAny(u8, s, ":");

        var i: usize = 0;
        while (parts.next()) |part| : (i += 1) {
            if (i >= length) {
                @compileError("Too many parts in MAC address string");
            }
            const byte = std.fmt.parseInt(u8, part, 16) catch {
                @compileError("Invalid byte in MAC address string");
            };
            bytes[i] = byte;
        }

        if (i != length) {
            @compileError("Too few parts in MAC address string");
        }

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

/// Prepend an Ethernet frame header to the given buffer.
pub fn prependHeader(dev: *net.Device, dest: []const u8, prot: net.Protocol, buf: *net.NetBuffer) net.Error!void {
    const dest_mac = MacAddr.from(dest);
    const src_mac = MacAddr.from(dev.getAddr());
    const hdr = try buf.prepend(@sizeOf(EtherHeader));

    const io = net.util.WireWriter(EtherHeader).new(hdr);
    io.write(.dest, dest_mac);
    io.write(.src, src_mac);
    io.write(.type, prot);
}

/// Input Ethernet frame data.
pub fn inputFrame(dev: *net.Device, data: []const u8) void {
    // Check length of the frame.
    if (data.len < @sizeOf(EtherHeader)) {
        return;
    }
    const io = net.util.WireReader(EtherHeader).new(data);

    // Check if the frame is destined to this device.
    const addr = MacAddr.from(dev.getAddr());
    const dest = io.read(.dest);
    if (!dest.eql(.broadcast) and !dest.eql(addr)) {
        return;
    }

    // Process the input frame.
    net.handleInput(
        dev,
        io.read(.type),
        data[@sizeOf(EtherHeader)..],
    ) catch |err| {
        log.warn("Failed to handle input: {}", .{err});
    };
}

// =============================================================
// Imports
// =============================================================

const log = std.log.scoped(.ether);
const std = @import("std");
const common = @import("common");
const urd = @import("urthr");
const net = urd.net;
