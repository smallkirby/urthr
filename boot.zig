//! Common module used for bootloader.

/// Header value put right before the Urthr kernel binary.
pub const UrthrHeader = extern struct {
    pub const hash_size = 8;

    /// Magic value.
    magic: [4]u8 = .{ 'U', 'R', 'T', 'H' },
    /// Reserved.
    _rsvd: u32 = 0,
    /// Size in bytes of the Urthr kernel binary.
    size: u64,
    /// Checksum of the Urthr kernel binary.
    checksum: [hash_size]u8,
    /// Virtual address to load the Urthr kernel.
    load_at: u64,
    /// Virtual address of the entry point.
    entry: u64,
    /// Reserved.
    _rsvd2: u64 = 0,

    comptime {
        if (@sizeOf(UrthrHeader) != 48) {
            @compileError("UrthrHeader size must be 48 bytes");
        }
    }

    /// Check if the header is valid.
    pub fn valid(self: *const UrthrHeader) bool {
        const magic_valid = std.mem.eql(u8, self.magic[0..], "URTH");
        const rsvd_valid = self._rsvd == 0;

        return magic_valid and rsvd_valid;
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
