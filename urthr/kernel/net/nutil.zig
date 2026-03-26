//! Utilities for network protocol stack.

/// Calculate the one's complement checksum of the given bytes.
///
/// The argument is expected to be in network byte order.
/// The return value is in native byte order.
pub fn calcChecksum(data: []const u8) u16 {
    return calcChecksumFrom(data, 0);
}

/// Calculate the one's complement checksum of the given bytes.
///
/// This function starts with the given initial value.
///
/// The argument is expected to be in network byte order.
/// The return value is in native byte order.
pub fn calcChecksumFrom(data: []const u8, initial: u16) u16 {
    var sum: u32 = initial;
    var i: usize = 0;

    while (i + 1 < data.len) : (i += 2) {
        sum += @as(u32, bits.fromBigEndian(std.mem.bytesToValue(u16, data[i .. i + 2])));
    }

    if (i < data.len) {
        sum += @as(u32, data[i]) << 8;
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
