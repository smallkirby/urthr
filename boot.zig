//! Common module used for bootloader.

/// Header value put right before the Urthr kernel binary.
pub const UrthrHeader = extern struct {
    pub const hash_size = 8;

    pub const Error = error{
        /// Failed to read from the reader.
        ReadFailed,
    };

    /// How the Urthr binary is encoded.
    pub const Encoding = enum(u32) {
        /// Not encoded.
        none = 0,
    };

    /// Magic value.
    magic: [4]u8 = .{ 'U', 'R', 'T', 'H' },
    /// Encoding type.
    encoding: Encoding = .none,
    /// Size in bytes of the Urthr kernel binary.
    size: u64,
    /// Size in bytes of the encoded Urthr kernel binary.
    encoded_size: u64,
    /// Checksum of the Urthr kernel binary.
    checksum: [hash_size]u8,
    /// Virtual address to load the Urthr kernel.
    load_at: u64,
    /// Virtual address of the entry point.
    entry: u64,

    comptime {
        if (@sizeOf(UrthrHeader) != 48) {
            @compileError("UrthrHeader size must be 48 bytes");
        }
    }

    /// Check if the header is valid.
    pub fn valid(self: *const UrthrHeader) bool {
        const magic_valid = std.mem.eql(u8, self.magic[0..], "URTH");

        return magic_valid;
    }

    /// Calculate checksum.
    pub fn calcChecksum(r: *std.Io.Reader) Error![hash_size]u8 {
        var ret: [hash_size]u8 = undefined;
        var rbuffer: [4096]u8 = undefined;

        var hasher = std.crypto.hash.Blake3.init(.{});

        while (true) {
            const n = try r.readSliceShort(rbuffer[0..]);
            hasher.update(rbuffer[0..n]);

            if (n < rbuffer.len) {
                break;
            }
        }

        hasher.final(&ret);

        return ret;
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
