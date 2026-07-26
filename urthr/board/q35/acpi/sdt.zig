//! System Description Table.

/// All system description table begin with this header.
pub const SdtHeader = extern struct {
    /// ASCII string of the table identifier.
    signature: [4]u8,
    /// Length of the table in bytes.
    length: u32,
    /// Revision of the structure corresponding to the table.
    revision: u8,
    /// Checksum of the entire table.
    checksum: u8,
    /// OEM-supplied string that identifies the OEM.
    oemid: [6]u8,
    /// OEM-supplied string that OEM uses to identify the particular table.
    oem_table_id: [8]u8,
    /// OEM-supplied revision number.
    oem_revision: u32,
    /// Vendor ID of utility that created the table.
    creator_id: u32,
    /// Revision of utility that created the table.
    creator_revision: u32,

    __end: void,

    comptime {
        if (size() != 36) {
            @compileError("Invalid SDT header size.");
        }
    }

    /// Calculate the checksum of the entire table pointed to by the given virtual address.
    pub fn calcSum(self: *const SdtHeader, base: usize) u8 {
        const ptr: [*]const u8 = @ptrFromInt(base);
        var sum: u8 = 0;
        for (ptr[0..self.length]) |b| {
            sum +%= b;
        }
        return sum;
    }

    /// Check if the signature of the SDT header matches the given signature.
    pub fn is(self: *const SdtHeader, table: Table) bool {
        return std.mem.eql(u8, table.id(), &self.signature);
    }

    /// Get the size of the SDT header.
    pub fn size() usize {
        return @offsetOf(SdtHeader, "__end");
    }
};

/// System description table kind.
pub const Table = enum {
    /// PCIe memory-mapped configuration space base address descriptor table.
    mcfg,

    /// Get the table identifier.
    pub fn id(self: Table) []const u8 {
        return switch (self) {
            .mcfg => "MCFG",
        };
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
