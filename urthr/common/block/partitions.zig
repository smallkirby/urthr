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
        .write = &write,
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

    /// Write blocks to the partition device.
    fn write(ctx: *anyopaque, lba: block.Lba, data: []const u8) block.Error!usize {
        const self: *Partition = @ptrCast(@alignCast(ctx));

        // Check bounds.
        const block_size = self.parent.getBlockSize();
        const num_blocks = data.len / block_size;
        if (lba + num_blocks > self.nsecs) {
            return block.Error.InvalidArgument;
        }

        // Translate LBA to parent device LBA.
        const parent_lba = self.lba + lba;
        return self.parent.vtable.write(self.parent.ptr, parent_lba, data);
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
        errdefer results.deinit(allocator);

        // Read the MBR sector.
        var buf: [size]u8 = undefined;
        try dev.readBlocks(0, &buf);

        // Parse partition table entries.
        // Note that tables are not aligned.
        const tables: [*]align(1) const TableEntry = @ptrCast(@alignCast(&buf[offset_partition_table]));
        for (tables[0..4]) |*table| {
            // Skip empty and GPT protective partitions.
            if (table.type == .empty or table.type == .protective_mbr) continue;

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
        try dev.readBlocks(0, &buf);

        // Check signature.
        return std.mem.eql(u8, buf[offset_signature .. offset_signature + 2], &signature);
    }
};

/// GUID Partition Table (GPT) partitioning scheme.
pub const Gpt = struct {
    /// Size of a GPT header sector in bytes.
    const size = 512;
    /// LBA of the GPT header.
    const header_lba: block.Lba = 1;
    /// GPT header signature.
    const signature = "EFI PART";

    /// Check if the given device uses GPT partitioning scheme.
    pub fn isMine(dev: Device) block.Error!bool {
        var buf: [size]u8 = undefined;
        try dev.readBlocks(header_lba, &buf);

        return std.mem.eql(u8, buf[0..signature.len], signature);
    }

    /// List partitions of the given block device.
    pub fn listPartitions(dev: Device, allocator: Allocator) block.Error![]Partition {
        var results = std.array_list.Aligned(Partition, null).empty;
        errdefer results.deinit(allocator);

        // Read GPT header.
        var hbuf: [size]u8 = undefined;
        try dev.readBlocks(header_lba, &hbuf);
        const header = GptHeader.from(&hbuf);

        // Find the partition entry array.
        const entry_lba = header.read(.entry, u64);
        const num_entries = header.read(.num_entries, u32);
        const entry_size = header.read(.entry_size, u32);
        if (entry_size == 0 or entry_size > size) {
            return block.Error.UnsupportedPartition;
        }
        const entries_per_block = size / entry_size;

        // Iterate over partition entries.
        var entries_read: u32 = 0;
        var lba = entry_lba;
        while (entries_read < num_entries) : (lba += 1) {
            var buf: [size]u8 = undefined;
            try dev.readBlocks(lba, &buf);

            // Iterate over entries in a block read.
            var i: usize = 0;
            while (i < entries_per_block and entries_read < num_entries) : ({
                i += 1;
                entries_read += 1;
            }) {
                const off = i * entry_size;
                const entry = PartitionEntry.from(buf[off..]);

                // Skip empty entries.
                if (entry.read(.type_guid, u128) == 0) {
                    continue;
                }

                const start_lba = entry.read(.start_lba, u64);
                const end_lba = entry.read(.end_lba, u64);
                try results.append(allocator, .{
                    .parent = dev,
                    .lba = start_lba,
                    .nsecs = end_lba - start_lba + 1,
                });
            }
        }

        return results.toOwnedSlice(allocator);
    }

    /// Partition Table Header located at LBA-1.
    const GptHeader = struct {
        /// Contents of the GPT header sector.
        buf: []const u8,

        fn from(buf: []const u8) GptHeader {
            return .{ .buf = buf };
        }

        fn read(self: GptHeader, field: Fields, comptime T: type) T {
            const offset: usize = @intFromEnum(field);
            return std.mem.readInt(T, self.buf[offset..][0..@sizeOf(T)], .little);
        }

        /// Offset of GPT header fields.
        const Fields = enum(usize) {
            /// Identifies GPT header. Must be "EFI PART".
            signature = 0,
            /// The starting LBA of GUID Partition Entry array.
            entry = 72,
            /// The number of Partition Entries in the GUID Partition Entry array.
            num_entries = 80,
            /// The size in bytes of each GUID Partition Entry.
            entry_size = 84,
        };
    };

    /// Partition Table Entry.
    const PartitionEntry = struct {
        /// Contents of the partition entry.
        buf: []const u8,

        fn from(buf: []const u8) PartitionEntry {
            return .{ .buf = buf };
        }

        fn read(self: PartitionEntry, field: Fields, comptime T: type) T {
            const offset: usize = @intFromEnum(field);
            return std.mem.readInt(T, self.buf[offset..][0..@sizeOf(T)], .little);
        }

        /// Offset of partition entry fields.
        const Fields = enum(usize) {
            /// Unique ID that defines the purpose and type of the partition.
            type_guid = 0,
            /// GUID that is unique for every partition entry.
            unique_guid = 16,
            /// Starting LBA of the partition.
            start_lba = 32,
            /// Ending LBA of the partition.
            end_lba = 40,
        };
    };
};

/// List partitions of the given block device.
pub fn listPartitions(dev: Device, allocator: Allocator) block.Error![]Partition {
    // GPT must be checked first so that the protective MBR is not misinterpreted.
    if (try Gpt.isMine(dev)) {
        return try Gpt.listPartitions(dev, allocator);
    }
    if (try Mbr.isMine(dev)) {
        return try Mbr.listPartitions(dev, allocator);
    }

    return block.Error.UnsupportedPartition;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const bits = common.bits;
const block = common.block;
const mmio = common.mmio;
const rtt = common.rtt;
const Device = block.Device;
