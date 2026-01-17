//! FAT32 filesystem implementation.

const Self = @This();

/// Block device backing the FAT32 filesystem.
device: block.Device,
/// BIOS Parameter Block information.
bpb: BpbInfo,
/// Memory allocator.
allocator: Allocator,

/// Index of a cluster.
const Cluster = u32;
/// Logical Block Addressing type.
const Lba = u64;

/// Initialize FAT32 filesystem from a block device.
///
/// The allocator is owned by this filesystem instance.
pub fn init(device: block.Device, allocator: Allocator) fs.Error!Self {
    rtt.expectEqual(device.getBlockSize(), sector_size);

    // Read boot sector.
    var buf: [sector_size]u8 = undefined;
    try device.readBlock(0, &buf);

    // Parse BPB info.
    const bpb = try BpbInfo.parse(&buf);

    return Self{
        .device = device,
        .bpb = bpb,
        .allocator = allocator,
    };
}

/// Get the filesystem interface.
pub fn filesystem(self: *Self) fs.FileSystem {
    return .{
        .ptr = self,
        .vtable = &fs_vtable,
    };
}

// =============================================================
// Filesystem Interface
// =============================================================

const fs_vtable = fs.FileSystem.Vtable{
    .getRootDir = &getRootDir,
    .openDir = &openDir,
};

fn getRootDir(ctx: *anyopaque) fs.Error!fs.Directory {
    const self: *Self = @ptrCast(@alignCast(ctx));

    return self.openDirByCluster(self.bpb.root_clus);
}

fn openDir(ctx: *anyopaque, entry: *const fs.Entry) fs.Error!fs.Directory {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const cluster: u32 = @intCast(entry.handle);

    return self.openDirByCluster(cluster);
}

/// Open a directory by cluster number.
fn openDirByCluster(self: *Self, cluster: u32) fs.Error!fs.Directory {
    const dir = try self.allocator.create(DirIteratorState);
    errdefer self.allocator.destroy(dir);

    dir.* = .{
        .fat32 = self,
        .cluster = cluster,
        .offset = 0,
        .buffer = undefined,
        .buffer_valid = false,
    };

    return .{
        .ptr = dir,
        .vtable = &dir_vtable,
    };
}

// =============================================================
// Directory Interface
// =============================================================

const dir_vtable = fs.Directory.Vtable{
    .iterator = &dirIterate,
};

fn dirIterate(ctx: *anyopaque, allocator: Allocator) fs.Error!fs.Iterator {
    const state: *DirIteratorState = @ptrCast(@alignCast(ctx));

    return .{
        .ptr = state,
        .vtable = &iter_vtable,
        .allocator = allocator,
    };
}

// =============================================================
// Iterator Interface
// =============================================================

const iter_vtable = fs.Iterator.Vtable{
    .next = &iterNext,
};

fn iterNext(ctx: *anyopaque, allocator: Allocator) fs.Error!?*fs.Entry {
    const state: *DirIteratorState = @ptrCast(@alignCast(ctx));
    return state.next(allocator);
}

/// Directory iterator state.
const DirIteratorState = struct {
    /// FAT32 filesystem this directory belongs to.
    fat32: *Self,
    /// Current cluster position.
    cluster: u32,
    /// Current offset in bytes within the cluster.
    offset: usize,
    /// Buffer for reading sectors.
    buffer: [sector_size]u8,
    /// Whether the buffer contains a valid sector.
    buffer_valid: bool,
    /// Long file name info.
    lfn: LfnInfo = .{},

    const LfnInfo = struct {
        /// Buffer for collecting long file name characters.
        buf: [LongNameEntry.max_name_len]u8 = undefined,
        /// Current length of LFN in the buffer.
        len: usize = 0,
        /// Expected next LFN sequence number.
        next_ord: u8 = 0,
        /// Checksum for LFN validation.
        checksum: u8 = 0,

        /// Check if the LFN info is valid for the given short file name.
        pub fn isValid(self: *const LfnInfo, sfn: *const [DirEntry.sfn_len]u8) bool {
            return self.len > 0 and self.next_ord == 0 and
                self.checksum == computeSfnChecksum(sfn);
        }

        /// Clear the stored LFN information.
        pub fn clear(self: *LfnInfo) void {
            self.len = 0;
            self.next_ord = 0;
            self.checksum = 0;
        }
    };

    /// Get the next directory entry.
    ///
    /// Returns `null` when there are no more entries.
    fn next(self: *DirIteratorState, allocator: Allocator) fs.Error!?*fs.Entry {
        while (true) {
            const entry_offset_in_sector = self.offset % sector_size;

            // Load buffer if needed (start of new sector).
            if (!self.buffer_valid or entry_offset_in_sector == 0) {
                const sector_in_cluster = self.offset / sector_size;
                const sectors_per_cluster = self.fat32.bpb.sec_per_clus;

                // If reached end of cluster, try to get next cluster in chain.
                if (sector_in_cluster >= sectors_per_cluster) {
                    if (try self.fat32.getNextCluster(self.cluster)) |nc| {
                        // Move to next cluster.
                        self.cluster = nc;
                        self.offset = 0;
                        continue;
                    } else {
                        // End of cluster chain.
                        return null;
                    }
                }

                const lba = self.fat32.clusterToLba(self.cluster);
                try self.fat32.device.readBlock(lba + sector_in_cluster, &self.buffer);
                self.buffer_valid = true;
            }

            // If reached end of sector, move to next sector.
            if (entry_offset_in_sector + @sizeOf(DirEntry) > sector_size) {
                self.offset = (self.offset / sector_size + 1) * sector_size;
                self.buffer_valid = false;
                continue;
            }

            const entry: *const DirEntry = @ptrCast(@alignCast(&self.buffer[entry_offset_in_sector]));
            self.offset += @sizeOf(DirEntry);

            // Check for end of directory.
            if (entry.isFree()) {
                return null;
            }

            // Skip deleted entries.
            if (entry.isDeleted()) {
                continue;
            }

            // Collect long file name entries.
            if (entry.isLongName()) {
                const lfn: *const LongNameEntry = @ptrCast(entry);
                const ord = lfn.getOrder();

                // Start of a new LFN sequence.
                if (lfn.isLast()) {
                    self.lfn.next_ord = ord;
                    self.lfn.checksum = lfn.chksum;
                    self.lfn.len = 0;
                }

                if (ord == self.lfn.next_ord and lfn.chksum == self.lfn.checksum) {
                    const start_pos = (ord - 1) * LongNameEntry.chars_per_entry;
                    const nw = lfn.extractChars(self.lfn.buf[start_pos..]);
                    self.lfn.len = @max(self.lfn.len, start_pos + nw);
                    self.lfn.next_ord = ord - 1;
                } else {
                    self.lfn.clear(); // sequence broken
                }
                continue;
            }

            // Skip volume label.
            if (entry.attr.volume_id) {
                continue;
            }

            const res = try allocator.create(fs.Entry);
            errdefer allocator.destroy(res);

            // Use LFN if valid, otherwise fall back to short name.
            const name = if (self.lfn.isValid(&entry.name))
                try allocator.dupe(u8, self.lfn.buf[0..self.lfn.len])
            else
                try parseName(entry, allocator);

            // Reset LFN state for next entry.
            self.lfn.clear();

            res.* = .{
                .name = name,
                .kind = if (entry.attr.directory) .directory else .file,
                .size = entry.file_size,
                .handle = entry.clusterNumber(),
            };

            return res;
        }
    }

    /// Parse name field to construct the file name.
    fn parseName(entry: *const DirEntry, allocator: Allocator) Allocator.Error![]const u8 {
        var len: usize = 0;
        var buf: [14]u8 = undefined;

        // Copy name part (8 bytes).
        for (entry.name[0 .. DirEntry.sfn_len - 3]) |c| {
            if (c == ' ') break;
            buf[len] = c;
            len += 1;
        }

        // Check if extension exists.
        if (entry.name[DirEntry.sfn_len - 3] != ' ') {
            buf[len] = '.';
            len += 1;

            // Copy extension part (3 bytes).
            for (entry.name[DirEntry.sfn_len - 3 .. DirEntry.sfn_len]) |c| {
                if (c == ' ') break;
                buf[len] = c;
                len += 1;
            }
        }

        return allocator.dupe(u8, buf[0..len]);
    }

    /// Compute checksum of the short name.
    fn computeSfnChecksum(name: *const [DirEntry.sfn_len]u8) u8 {
        var sum: u8 = 0;
        for (name) |c| {
            sum = ((sum >> 1) | ((sum & 1) << 7)) +% c;
        }
        return sum;
    }
};

/// Convert cluster number to LBA.
fn clusterToLba(self: *const Self, cluster: Cluster) Lba {
    const first_data_cluster = 2;
    const first_data_sector = self.bpb.rsvd_sec_cnt +
        (self.bpb.num_fats * self.bpb.fat_sz32);

    return first_data_sector + (cluster - first_data_cluster) * self.bpb.sec_per_clus;
}

/// Get the next cluster in the FAT chain.
///
/// Returns null if this is the last cluster.
fn getNextCluster(self: *Self, cluster: Cluster) fs.Error!?Cluster {
    // Calculate FAT sector and offset.
    const fat_offset = cluster * fat_entry_size;
    const fat_sector = self.bpb.rsvd_sec_cnt + (fat_offset / sector_size);
    const entry_offset = fat_offset % sector_size;

    // Read FAT sector.
    var buf: [sector_size]u8 = undefined;
    try self.device.readBlock(fat_sector, &buf);

    // Read FAT entry (little-endian u32) and apply mask.
    const entry = std.mem.readInt(
        u32,
        buf[entry_offset..][0..4],
        .little,
    ) & fat_mask;

    // Check for EOC marker.
    if (entry >= fat_eoc_min) {
        return null;
    }

    // Check for bad cluster marker.
    if (entry == fat_bad_cluster) {
        return fs.Error.CorruptedData;
    }

    // Check for free cluster (should not appear in chain).
    if (entry == fat_free_cluster) {
        return fs.Error.CorruptedData;
    }

    return entry;
}

/// BPB information extracted from the boot sector.
const BpbInfo = struct {
    /// Count of bytes per sector.
    bytes_per_sect: u16,
    /// Number of sectors per cluster.
    sec_per_clus: u8,
    /// Number of reserved sectors.
    rsvd_sec_cnt: u16,
    /// Number of FATs.
    num_fats: u8,
    /// Count of sectors occupied by ONE FAT.
    fat_sz32: u32,
    /// Cluster number of the first cluster of the root directory.
    root_clus: Cluster,

    /// Parse BPB from boot sector buffer.
    fn parse(buf: *const [sector_size]u8) fs.Error!BpbInfo {
        const bpb: *const Bpb = @ptrCast(buf);

        // Check boot signature.
        if (!std.mem.eql(u8, &bpb.fil_sys_type, fat32_signature)) {
            return fs.Error.InvalidFilesystem;
        }
        if (bpb.boot_sig != Bpb.valid_boot_sig) {
            return fs.Error.InvalidFilesystem;
        }

        // FAT32 specific validation.
        if (bpb.root_ent_cnt != 0 or bpb.fat_sz16 != 0) {
            return fs.Error.InvalidFilesystem;
        }

        return BpbInfo{
            .bytes_per_sect = bpb.bytes_per_sec,
            .sec_per_clus = bpb.sec_per_clus,
            .rsvd_sec_cnt = bpb.rsvd_sec_cnt,
            .num_fats = bpb.num_fats,
            .fat_sz32 = bpb.fat_sz32,
            .root_clus = bpb.root_clus,
        };
    }
};

// =============================================================
// FAT32 data structures
// =============================================================

/// Sector size in bytes.
const sector_size = 512;
/// FAT entry size in bytes of FAT32.
const fat_entry_size = 4;

/// FAT32 filesystem signature in Boot Sector.
const fat32_signature = "FAT32   ";

/// Mask to extract valid cluster number from FAT entry.
const fat_mask = 0x0FFF_FFFF;
/// Minimum value indicating end-of-cluster-chain.
const fat_eoc_min = 0x0FFFFFF8;
/// Bad cluster marker.
const fat_bad_cluster = 0x0FFF_FFF7;
/// Free cluster marker.
const fat_free_cluster = 0x0000_0000;

/// BIOS Parameter Block (BPB) in a Boot Sector of FAT32.
const Bpb = extern struct {
    /// Valid boot sector signature.
    const valid_boot_sig = 0x29;

    /// Jump instruction to boot code.
    jmpboot: [3]u8 align(1),
    /// OEM Name in ASCII.
    oemname: [8]u8 align(1),
    /// Count of bytes per sector.
    bytes_per_sec: u16 align(1),
    /// Number of sectors per allocation unit.
    sec_per_clus: u8 align(1),
    /// Number of reserved sectors in the Reserved region of the volume.
    rsvd_sec_cnt: u16 align(1),
    /// The count of FAT data structures on the volume. Always 2 for FAT32.
    num_fats: u8 align(1),
    /// Must be 0 for FAT32.
    root_ent_cnt: u16 align(1),
    /// Must be 0 for FAT32.
    tot_sec16: u16 align(1),
    /// Media type.
    media: u8 align(1),
    /// Must be 0 for FAT32.
    fat_sz16: u16 align(1),
    /// Sectors per track for interrupt 0x13.
    sec_per_trk: u16 align(1),
    /// Number of heads for interrupt 0x13.
    num_heads: u16 align(1),
    /// Count of hidden sectors preceding the partition that contains this FAT volume.
    hidd_sec: u32 align(1),
    /// Count of sectors on the volume.
    tot_sec32: u32 align(1),

    /// Count of sectors occupied by ONE FAT data structure.
    fat_sz32: u32 align(1),
    /// Flags.
    ext_flags: u16 align(1),
    /// Revision number.
    fs_ver: u16 align(1),
    /// Cluster number of the first cluster of the root directory.
    root_clus: Cluster align(1),
    /// Sector number of the FSInfo structure in the reserved area of the FAT32 volume.
    fs_info: u16 align(1),
    /// Sector number of the copy of the boot record.
    bk_boot_sec: u16 align(1),
    /// Must be 0 for FAT32.
    reserved: [12]u8 align(1),
    /// Int 0x13 drive number.
    drv_num: u8 align(1),
    /// Reserved.
    reserved1: u8 align(1),
    /// Extended boot signature to identify if the next three fields are valid.
    boot_sig: u8 align(1),
    /// Volume serial number.
    vol_id: u32 align(1),
    /// Volume label in ASCII.
    vol_lab: [11]u8 align(1),
    /// Always "FAT32   ".
    fil_sys_type: [8]u8 align(1),

    comptime {
        const size = @bitSizeOf(Bpb);
        const expected = 90 * @bitSizeOf(u8);
        urd.comptimeAssert(size == expected, "Invalid size of BPB: expected {d} bits, found {d} bits", .{ expected, size });
    }
};

/// FAT32 Long File Name Entry.
const LongNameEntry = extern struct {
    /// Sequence number.
    order: u8,
    /// Characters 1-5 (UCS-2).
    name1: [5]u16 align(1),
    /// Attributes (always 0x0F for LFN).
    attr: DirEntry.Attributes,
    /// Entry type (always 0 for LFN).
    entry_type: u8,
    /// Checksum of short name.
    chksum: u8,
    /// Characters 6-11 (UCS-2).
    name2: [6]u16 align(1),
    /// First cluster (always 0).
    first_clus_lo: u16 align(1),
    /// Characters 12-13 (UCS-2).
    name3: [2]u16 align(1),

    /// Mask for sequence number.
    const order_mask = 0x1F;
    /// Flag indicating last LFN entry.
    const last_entry_flag = 0x40;
    /// Maximum number of LFN entries.
    const max_entries = 20;
    /// Characters per LFN entry.
    const chars_per_entry = 13;
    /// Maximum long file name length.
    const max_name_len = max_entries * chars_per_entry;

    /// Get the sequence number (1-based index).
    fn getOrder(self: LongNameEntry) u8 {
        return self.order & order_mask;
    }

    /// Check if this is the last LFN entry.
    fn isLast(self: LongNameEntry) bool {
        return (self.order & last_entry_flag) != 0;
    }

    /// Extract characters from this entry to the buffer.
    ///
    /// Returns the number of characters written.
    fn extractChars(self: *const LongNameEntry, buf: []u8) usize {
        var pos: usize = 0;

        const targets = [_]struct {
            chars: [*]align(1) const u16,
            len: usize,
        }{
            .{ .chars = &self.name1, .len = 5 },
            .{ .chars = &self.name2, .len = 6 },
            .{ .chars = &self.name3, .len = 2 },
        };

        for (targets) |target| {
            for (target.chars[0..target.len]) |c| {
                if (c == 0 or c == 0xFFFF) return pos;

                if (pos < buf.len) {
                    buf[pos] = if (c < 128) @intCast(c) else '?';
                    pos += 1;
                }
            }
        }

        return pos;
    }

    comptime {
        urd.comptimeAssert(32 * 8 == @bitSizeOf(LongNameEntry), "Invalid size of LongNameEntry", .{});
    }
};

/// FAT32 Directory Entry.
const DirEntry = extern struct {
    /// Length of short file name.
    pub const sfn_len = 11;

    /// Short name (8.3 format).
    name: [sfn_len]u8,
    /// File attributes.
    attr: Attributes,
    /// Reserved for Windows NT.
    _rsvd: u8 = 0,
    /// Creation time fine resolution (10ms units).
    create_time_tenth: u8,
    /// Creation time.
    create_time: u16,
    /// Creation date.
    create_date: u16,
    /// Last access date.
    access_date: u16,
    /// High word of first cluster.
    first_cluster_high: u16,
    /// Last modification time.
    write_time: u16,
    /// Last modification date.
    write_date: u16,
    /// Low word of first cluster.
    first_cluster_low: u16,
    /// File size in bytes.
    file_size: u32,

    const Attributes = packed struct(u8) {
        /// Read-only.
        read_only: bool,
        /// Hidden file.
        hidden: bool,
        /// System file.
        system: bool,
        /// Volume ID.
        volume_id: bool,
        /// Directory.
        directory: bool,
        /// Archive.
        archive: bool,
        /// Reserved.
        _rsvd: u2 = 0,

        const long_name = Attributes{
            .read_only = true,
            .hidden = true,
            .system = true,
            .volume_id = true,
            .directory = false,
            .archive = false,
        };
    };

    /// Check if the attribute indicates a long file name entry.
    fn isLongName(self: DirEntry) bool {
        return self.attr == Attributes.long_name;
    }

    /// Check if the entry is unused.
    fn isFree(self: DirEntry) bool {
        return self.name[0] == 0;
    }

    /// Check if the entry is deleted.
    fn isDeleted(self: DirEntry) bool {
        return self.name[0] == 0xE5;
    }

    /// Get the starting cluster number of the entry.
    fn clusterNumber(self: DirEntry) u32 {
        return bits.concat(u32, self.first_cluster_high, self.first_cluster_low);
    }

    comptime {
        urd.comptimeAssert(32 * 8 == @bitSizeOf(DirEntry), "Invalid size of DirEntry", .{});
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const bits = common.bits;
const block = common.block;
const rtt = common.rtt;
const urd = @import("urthr");
const fs = urd.fs;
