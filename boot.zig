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
        /// zlib compressed.
        zlib = 1,
    };

    /// Magic value.
    magic: [4]u8 = .{ 'U', 'R', 'T', 'H' },
    /// Encoding type.
    encoding: Encoding = .none,
    /// Size in bytes of the Urthr kernel binary.
    size: u64,
    /// Size in bytes of the encoded Urthr kernel binary.
    encoded_size: u64,
    /// Size in bytes of the memory size including NOBITS sections.
    mem_size: u64,
    /// Checksum of the Urthr kernel binary.
    checksum: [hash_size]u8,
    /// Virtual address to load the Urthr kernel.
    load_at: u64,
    /// Virtual address of the entry point.
    entry: u64,
    /// Reserved.
    _56: u64 = 0,

    comptime {
        if (@sizeOf(UrthrHeader) != 64) {
            @compileError("UrthrHeader size must be 56 bytes");
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

/// Information passed to Urthr kernel from Wyrd bootloader.
pub const BootInfo = switch (builtin.cpu.arch) {
    .aarch64 => void,

    .x86_64 => extern struct {
        /// Located at .boot_services_data.
        memory_map: MemoryMap,

        const uefi = std.os.uefi;

        /// Memory map provided by UEFI.
        pub const MemoryMap = extern struct {
            buffer_size: usize,
            descriptors: [*]uefi.tables.MemoryDescriptor,
            map_size: usize,
            map_key: uefi.tables.MemoryMapKey,
            descriptor_size: usize,
            descriptor_version: u32,
        };

        /// Memory descriptor iterator.
        pub const MemoryDescriptorIterator = struct {
            const Self = @This();
            const Md = uefi.tables.MemoryDescriptor;

            descriptors: [*]Md,
            current: *Md,
            descriptor_size: usize,
            total_size: usize,

            pub fn new(map: MemoryMap) Self {
                return Self{
                    .descriptors = map.descriptors,
                    .current = @ptrCast(map.descriptors),
                    .descriptor_size = map.descriptor_size,
                    .total_size = map.map_size,
                };
            }

            pub fn next(self: *Self) ?*Md {
                const ret = self.peek() orelse return null;
                self.current = @ptrFromInt(@intFromPtr(self.current) + self.descriptor_size);
                return ret;
            }

            pub fn peek(self: *Self) ?*Md {
                if (@intFromPtr(self.current) >= @intFromPtr(self.descriptors) + self.total_size) {
                    return null;
                }
                return self.current;
            }
        };
    },

    else => @compileError("Unsupported architecture"),
};

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const std = @import("std");
