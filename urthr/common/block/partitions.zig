//! Partition types of block devices.

/// Partition device wrapping a partition as a block device.
///
/// This structure wraps a partition and provides block device interface
/// with offset translation to the parent device.
pub const Partition = struct {
    /// Parent block device interface.
    parent: block.Device,
    /// Starting LBA of the partition.
    lba: block.Lba,
    /// Number of sectors in the partition.
    nsecs: u64,

    /// Block Device interface vtable.
    const vtable = block.Device.Vtable{
        .blockSize = &blockSize,
        .blockCount = &blockCount,
        .read = &read,
    };

    /// Get the block size of the partition device.
    fn blockSize(ctx: *const anyopaque) usize {
        const self: *const Partition = @ptrCast(@alignCast(ctx));
        return self.parent.getBlockSize();
    }

    /// Get the number of blocks of the partition.
    fn blockCount(ctx: *const anyopaque) u64 {
        const self: *const Partition = @ptrCast(@alignCast(ctx));
        return self.nsecs;
    }

    /// Read blocks from the partition device.
    fn read(ctx: *anyopaque, lba: block.Lba, buffer: []u8) block.Error!usize {
        const self: *Partition = @ptrCast(@alignCast(ctx));

        // Check bounds.
        const block_size = self.parent.getBlockSize();
        const num_blocks = buffer.len / block_size;
        if (lba + num_blocks > self.nsecs) {
            return block.Error.InvalidArgument;
        }

        // Translate LBA to parent device LBA.
        const parent_lba = self.lba + lba;
        return self.parent.vtable.read(self.parent.ptr, parent_lba, buffer);
    }

    /// Get the block device interface for this partition.
    pub fn interface(self: *Partition) block.Device {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

/// Master Boot Record (MBR) partitioning scheme.
pub const Mbr = struct {
    /// Size of MBR in bytes.
    const size = 512;

    /// Offset of bootstrap code area.
    const offset_bootstrap_code = 0x000;
    /// Offset of the partition table entries.
    const offset_partition_table = 0x1BE;
    /// Offset of the signature field.
    const offset_signature = 0x1FE;

    /// MBR signature bytes.
    const signature = [_]u8{ 0x55, 0xAA };

    /// Partition table entry.
    const TableEntry = packed struct(u128) {
        /// Drive attribute.
        attr: enum(u8) {
            /// Inactive partition.
            inactive = 0x00,
            /// Active (bootable) partition.
            active = 0x80,

            _,
        },
        /// CHS address of partition start.
        chs_start: u24,
        /// Partition type.
        type: PartitionType,
        /// CHS address of partition end.
        chs_end: u24,
        /// LBA of partition start.
        lba: u32,
        /// Size of partition in sectors.
        nsecs: u32,
    };

    /// Partition type.
    const PartitionType = enum(u8) {
        /// Unknown, empty entry.
        empty = 0x00,
        /// 16-bit FAT.
        fat16 = 0x04,
        /// 32-bit FAT.
        fat32 = 0x0B,
        /// 32-bit FAT, using Logical Block Addressing.
        fat32lba = 0x0C,
        /// Linux Swap partition.
        linux_swap = 0x82,
        /// Linux Native partition.
        linux_native = 0x83,
        /// GPT Protective MBR.
        protective_mbr = 0xEE,

        _,
    };

    /// List partitions of the given block device.
    pub fn listPartitions(dev: Device, allocator: Allocator) block.Error![]Partition {
        var results = std.array_list.Aligned(Partition, null).empty;

        // Read the MBR sector.
        var buf: [size]u8 = undefined;
        try dev.readBlock(0, &buf);

        // Parse partition table entries.
        // Note that tables are not aligned.
        const tables: [*]align(1) const TableEntry = @ptrCast(@alignCast(&buf[offset_partition_table]));
        for (tables[0..4]) |*table| {
            // Skip empty partitions.
            if (table.type == .empty) continue;

            try results.append(allocator, .{
                .parent = dev,
                .lba = table.lba,
                .nsecs = table.nsecs,
            });
        }

        return results.toOwnedSlice(allocator);
    }

    /// Check if the given device uses MBR partitioning scheme.
    pub fn isMine(dev: Device) block.Error!bool {
        var buf: [size]u8 = undefined;
        try dev.readBlock(0, &buf);

        // Check signature.
        return std.mem.eql(u8, buf[offset_signature .. offset_signature + 2], &signature);
    }
};

/// GUID Partition Table (GPT) partitioning scheme.
pub const Gpt = struct {
    /// Check if the given device uses GPT partitioning scheme.
    pub fn isMine(_: Device) block.Error!bool {
        @panic("Gpt.isMine: Not implemented");
    }

    /// List partitions of the given block device.
    pub fn listPartitions(_: Device, _: Allocator) block.Error![]Partition {
        @panic("Gpt.listPartitions: Not implemented");
    }
};

/// List partitions of the given block device.
pub fn listPartitions(dev: Device, allocator: Allocator) block.Error![]Partition {
    if (try Mbr.isMine(dev)) {
        return try Mbr.listPartitions(dev, allocator);
    }
    if (try Gpt.isMine(dev)) {
        return try Gpt.listPartitions(dev, allocator);
    }

    return block.Error.UnsupportedPartition;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const block = common.block;
const rtt = common.rtt;
const Device = block.Device;
