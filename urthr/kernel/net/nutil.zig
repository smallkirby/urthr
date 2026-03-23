//! Utilities for network protocol stack.

/// Calculate the one's complement checksum of the given bytes.
///
/// The argument is expected to be in network byte order.
/// The return value is in native byte order.
pub fn calcChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;

    while (i + 1 < data.len) : (i += 2) {
        sum += @as(u32, bits.fromBigEndian(std.mem.bytesToValue(u16, data[i .. i + 2])));
    }

    if (i < data.len) {
        sum += @as(u32, data[i]);
    }

    while ((sum >> 16) != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return ~@as(u16, @intCast(sum));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const bits = common.bits;
