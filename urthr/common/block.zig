//! Block devices.

pub const partitions = @import("block/partitions.zig");

pub const Error = error{
    /// Given argument is invalid.
    InvalidArgument,
    /// Failed to allocate memory.
    OutOfMemory,
    /// Partition type is unsupported.
    UnsupportedPartition,
};

/// Logical Block Addressing (LBA) type.
pub const Lba = u64;

/// Block device interface.
pub const Device = struct {
    const Self = @This();

    /// The type erased pointer to the block device implementation.
    ptr: *anyopaque,
    /// The vtable for the block device.
    vtable: *const Vtable,

    pub const Vtable = struct {
        /// Get the block size of the device in bytes.
        blockSize: *const fn (ctx: *const anyopaque) usize,
        /// Get the number of blocks of the device.
        blockCount: *const fn (ctx: *const anyopaque) u64,

        /// Read blocks from the device into the given buffer.
        ///
        /// `lba` is the starting block address to read from.
        /// `buffer` is the destination buffer to read into.
        ///
        /// The buffer size must be a multiple of the block size.
        ///
        /// Returns the number of bytes read.
        read: *const fn (ctx: *anyopaque, lba: Lba, buffer: []u8) Error!usize,
    };

    /// Get the block size of the device in bytes.
    pub fn getBlockSize(self: Self) usize {
        return self.vtable.blockSize(self.ptr);
    }

    /// Get the number of blocks of the device.
    pub fn getBlockCount(self: Self) u64 {
        return self.vtable.blockCount(self.ptr);
    }

    /// Read a single block from the device into the given buffer.
    ///
    /// The buffer size must be equal to the block size.
    pub fn readBlock(self: Self, lba: Lba, buffer: []u8) Error!void {
        if (buffer.len != self.getBlockSize()) {
            return Error.InvalidArgument;
        }

        _ = try self.vtable.read(self.ptr, lba, buffer);
    }
};
