//! Root System Description Pointer Structure.

pub const Rsdp = extern struct {
    /// "RSD PTR " signature.
    signature: [8]u8,
    /// Checksum of first 20 bytes.
    checksum: u8,
    /// OEM-supplied string that identifies the OEM.
    oemid: [6]u8,
    /// Revision of this structure.
    revision: u8,
    /// 32-bit physical address of the RSDT.
    rsdt_address: u32,
    /// Length of the table in bytes.
    length: u32,
    /// 64-bit physical address of the XSDT.
    xsdt_address: u64,
    /// Checksum of entire table.
    extended_checksum: u8,
    /// Reserved.
    reserved: [3]u8,

    __end: void,

    comptime {
        if (size() != 36) {
            @compileError("Invalid RSDP size.");
        }
    }

    /// Calculate the sum of RSDP bytes.
    fn calcSum(self: *const Rsdp, len: usize) u8 {
        const ptr: [*]const u8 = @ptrCast(self);
        var sum: u8 = 0;
        for (ptr[0..len]) |b| {
            sum +%= b;
        }
        return sum;
    }

    /// Get the size of the RSDP structure.
    fn size() usize {
        return @offsetOf(Rsdp, "__end");
    }
};

/// Parse RSDP structure pointed to by `ptr`.
///
/// Returns null if the structure is invalid.
pub fn parse(ptr: usize) ?Rsdp {
    var self: Rsdp = undefined;
    @memcpy(
        std.mem.asBytes(&self)[0..Rsdp.size()],
        @as([*]const u8, @ptrFromInt(ptr))[0..Rsdp.size()],
    );

    if (!std.mem.eql(u8, "RSD PTR ", &self.signature)) {
        log.err("Invalid signature.", .{});
        return null;
    }
    if (self.revision != 2) {
        log.err("Unsupported revision: {d}", .{self.revision});
        return null;
    }
    if (self.length != Rsdp.size()) {
        log.err("Invalid length: {d}", .{self.length});
        return null;
    }
    if (self.calcSum(20) != 0) {
        log.err("Invalid checksum.", .{});
        return null;
    }
    if (self.calcSum(Rsdp.size()) != 0) {
        log.err("Invalid extended checksum.", .{});
        return null;
    }

    return self;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.rsdp);
