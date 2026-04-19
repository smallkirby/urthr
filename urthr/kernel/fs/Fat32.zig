//! FAT32 filesystem implementation.

const Self = @This();

/// Block device backing the FAT32 filesystem.
device: block.Device,
/// BIOS Parameter Block information.
bpb: BpbInfo,
/// Root directory inode.
root: *InodeImpl,
/// Memory allocator.
allocator: Allocator,

/// Index of a cluster.
const Cluster = u32;
/// Logical Block Addressing type.
const Lba = u64;

/// Initialize FAT32 filesystem from a block device.
///
/// The allocator is owned by this filesystem instance.
pub fn init(device: block.Device, allocator: Allocator) fs.Error!*Self {
    rtt.expectEqual(device.getBlockSize(), sector_size);

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    // Read boot sector.
    var buf: [sector_size]u8 = undefined;
    try device.readBlock(0, &buf);

    // Parse BPB info.
    const bpb = try BpbInfo.parse(&buf);

    // Create root directory inode.
    const root = try allocator.create(InodeImpl);
    errdefer allocator.destroy(root);
    root.* = .{
        .common = .{
            .number = 1,
            .size = 0,
            .ftype = .directory,
            .iops = inode_vtable,
            .fops = file_vtable,
        },
        .fat32 = self,
        .cluster = bpb.root_clus,
    };
    root.common.ref();

    self.* = .{
        .device = device,
        .bpb = bpb,
        .allocator = allocator,
        .root = root,
    };
    return self;
}

/// Get the filesystem interface.
pub fn filesystem(self: *Self) fs.FileSystem {
    return .{
        .ptr = self,
        .vtable = &fs_vtable,
        .root = &self.root.common,
    };
}

// =============================================================
// Filesystem Interface
// =============================================================

const fs_vtable = fs.FileSystem.Vtable{
    .getLabel = fsGetLabel,
    .open = fopen,
};

fn fsGetLabel(ctx: *const anyopaque, allocator: Allocator) fs.Error![]const u8 {
    const self: *const Self = @ptrCast(@alignCast(ctx));
    return allocator.dupe(u8, self.bpb.label[0..]);
}

/// Open and create a file instance for the given inode.
fn fopen(inode: *fs.Inode, allocator: Allocator) fs.Error!*anyopaque {
    const file = try allocator.create(FileImpl);
    errdefer allocator.destroy(file);

    file.* = .{
        .fat32 = InodeImpl.from(inode).fat32,
        .start_cluster = InodeImpl.from(inode).cluster,
    };

    return @ptrCast(file);
}

// =============================================================
// Inode Interface
// =============================================================

const inode_vtable = fs.Inode.Ops{
    .lookup = &ilookup,
    .deinit = &ideinit,
};

/// FAT32-specific inode implementation.
const InodeImpl = struct {
    /// Common part of inode.
    common: fs.Inode,
    /// FAT32 filesystem this inode belongs to.
    fat32: *Self,
    /// Cluster number of the inode.
    cluster: Cluster,

    pub fn from(inode: *fs.Inode) *InodeImpl {
        return @fieldParentPtr("common", inode);
    }
};

/// Lookup an inode by its name in a directory inode.
fn ilookup(dir: *fs.Inode, name: []const u8) fs.Error!?*fs.Inode {
    rtt.expect(dir.ftype == .directory);

    const ctx = InodeImpl.from(dir);
    const self = ctx.fat32;
    var iter = DirIterator{
        .fat32 = self,
        .cluster = ctx.cluster,
    };

    // Create upper case name for comparson.
    var uname = try self.allocator.alloc(u8, name.len);
    defer self.allocator.free(uname);
    uname = std.ascii.upperString(uname, name);

    while (try iter.next(self.allocator)) |result| {
        defer result.deinit(self.allocator);

        if (std.mem.eql(u8, result.name, uname)) {
            const inode = try self.allocator.create(InodeImpl);
            errdefer self.allocator.destroy(inode);

            inode.* = .{
                .common = .{
                    .number = calcInodeNumber(result.pos),
                    .size = result.entry.file_size,
                    .ftype = if (result.entry.attr.directory) .directory else .regular,
                    .iops = inode_vtable,
                    .fops = file_vtable,
                },
                .fat32 = self,
                .cluster = result.entry.clusterNumber(),
            };
            inode.common.ref();

            return &inode.common;
        }
    } else return null;
}

/// Release resources associated with an inode.
fn ideinit(inode: *fs.Inode) void {
    const ctx = InodeImpl.from(inode);
    ctx.fat32.allocator.destroy(ctx);
}

/// Calculate inode number.
///
/// FAT32 does not have a real inode number.
/// So we synthesize a unique number for each file based on its directory entry position.
fn calcInodeNumber(pos: DirIterator.DirEntryPosition) u64 {
    const index_offset: u8 = @intCast(pos.offset / @sizeOf(DirEntry));
    const sector: u64 = @as(u56, @truncate(pos.sector));
    return (sector << 8) + index_offset;
}

/// Directory iterator.
const DirIterator = struct {
    /// FAT32 filesystem this directory belongs to.
    fat32: *Self,
    /// Current cluster position.
    cluster: u32,
    /// Current offset in bytes within the cluster.
    offset: usize = 0,
    /// Total offset in bytes from the start of the directory stream.
    consumed: usize = 0,
    /// Buffer for reading sectors.
    buffer: [sector_size]u8 = undefined,
    /// Whether the buffer contains a valid sector.
    buffer_valid: bool = false,
    /// Long file name info.
    lfn: LfnInfo = .{},

    const Result = struct {
        /// Directory entry.
        entry: *const DirEntry,
        /// Name of the entry.
        ///
        /// `entry` also contains the short name, but caller must use this field to get the correct name.
        name: []const u8,
        /// Position of the directory entry.
        pos: DirEntryPosition,

        pub fn deinit(self: *const Result, allocator: Allocator) void {
            allocator.free(self.name);
            allocator.destroy(self.entry);
        }
    };

    const DirEntryPosition = struct {
        /// Sector number of the directory entry from the start of the partition.
        sector: usize,
        /// Offset of the directory entry in bytes from the start of the sector.
        offset: usize,
    };

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
    fn next(self: *DirIterator, allocator: Allocator) fs.Error!?Result {
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
            self.consumed += @sizeOf(DirEntry);

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

            // Use LFN if valid, otherwise fall back to short name.
            const name = if (self.lfn.isValid(&entry.name)) blk: {
                const buf = try allocator.alloc(u8, self.lfn.len);
                break :blk std.ascii.upperString(buf, self.lfn.buf[0..buf.len]);
            } else try parseName(entry, allocator);
            errdefer allocator.free(name);

            // Reset LFN state for next entry.
            self.lfn.clear();

            // Copy the entry.
            const cloned = try allocator.create(DirEntry);
            errdefer allocator.destroy(cloned);
            cloned.* = entry.*;

            return .{
                .entry = cloned,
                .name = name,
                .pos = .{
                    .sector = self.fat32.clusterToLba(self.cluster) + (self.offset - @sizeOf(DirEntry)) / sector_size,
                    .offset = (self.offset - @sizeOf(DirEntry)) % sector_size,
                },
            };
        }
    }

    /// Seek to the given position in the directory stream.
    fn seek(self: *DirIterator, pos: usize, allocator: Allocator) fs.Error!void {
        if (pos == 0) return;

        while (try self.next(allocator)) |result| {
            result.deinit(allocator);
            if (self.consumed >= pos) {
                rtt.expect(self.consumed == pos);
                return;
            }
        } else return fs.Error.CorruptedData;
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

        const name = try allocator.alloc(u8, len);
        return std.ascii.upperString(name, buf[0..len]);
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

// =============================================================
// File Interface
// =============================================================

const file_vtable = fs.File.Ops{
    .iterate = fiterate,
    .read = fread,
};

const FileImpl = struct {
    /// FAT32 filesystem this file belongs to.
    fat32: *Self,
    /// Starting cluster of the file.
    start_cluster: Cluster,

    pub fn from(file: *fs.File) *FileImpl {
        return @ptrCast(@alignCast(file.ctx));
    }
};

/// Get the next file entry in a directory file.
fn fiterate(iter: *fs.File.Iterator, allocator: Allocator) fs.Error!?fs.File.IterResult {
    const file = iter.file;
    const inode = InodeImpl.from(file.path.dentry.inode);
    var diter = DirIterator{
        .fat32 = inode.fat32,
        .cluster = inode.cluster,
    };
    diter.seek(iter.offset, allocator) catch return null;

    if (try diter.next(allocator)) |result| {
        iter.offset = diter.consumed;
        return .{
            .name = try allocator.dupe(u8, result.name),
            .inum = calcInodeNumber(result.pos),
            .type = if (result.entry.attr.directory) .directory else .regular,
        };
    } else return null;
}

/// Read data from a regular file.
fn fread(file: *fs.File, buf: []u8, offset: usize) fs.Error!usize {
    const ctx = FileImpl.from(file);

    const fat32 = ctx.fat32;
    const bytes_per_cluster = @as(u64, fat32.bpb.sec_per_clus) * sector_size;

    // Seek to the cluster that contains `offset`.
    var clus = ctx.start_cluster; // cluster number of the current position in the file
    var clus_file_offset: u64 = 0; // offset of the current cluster in the file
    while (clus_file_offset + bytes_per_cluster <= offset) : (clus_file_offset += bytes_per_cluster) {
        clus = try fat32.getNextCluster(clus) orelse return fs.Error.CorruptedData;
    }

    // Read sector by sector, copying into the caller's buffer.
    var bytes_read: usize = 0;
    var cur_offset = offset;
    var cur_clus = clus;
    var cur_clus_file_offset = clus_file_offset;

    while (bytes_read < buf.len) {
        const offset_in_clus = cur_offset - cur_clus_file_offset;
        const sector_in_clus = offset_in_clus / sector_size;
        const offset_in_sec = offset_in_clus % sector_size;

        const lba = fat32.clusterToLba(cur_clus) + sector_in_clus;
        var sec_buf: [sector_size]u8 = undefined;
        try fat32.device.readBlock(lba, &sec_buf);

        const to_copy = @min(sector_size - offset_in_sec, buf.len - bytes_read);
        @memcpy(buf[bytes_read..][0..to_copy], sec_buf[offset_in_sec..][0..to_copy]);

        bytes_read += to_copy;
        cur_offset += to_copy;

        // If we crossed a cluster boundary, follow the FAT chain to seek the next cluster.
        if (cur_offset - cur_clus_file_offset >= bytes_per_cluster) {
            rtt.expect(cur_offset == cur_clus_file_offset + bytes_per_cluster);
            cur_clus = try fat32.getNextCluster(cur_clus) orelse break;
            cur_clus_file_offset += bytes_per_cluster;
        }
    }

    return bytes_read;
}

// =============================================================
// Utilities
// =============================================================

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
    /// Number of sectors per cluster.
    sec_per_clus: u8,
    /// Number of reserved sectors.
    rsvd_sec_cnt: u16,
    /// Number of FATs.
    num_fats: u8,
    /// Count of sectors occupied by ONE FAT.
    fat_sz32: u32,
    /// Volume label.
    label: [11]u8,
    /// Cluster number of the first cluster of the root directory.
    root_clus: Cluster,

    /// Parse BPB from boot sector buffer.
    fn parse(buf: *const [sector_size]u8) fs.Error!BpbInfo {
        const bpb: *const Bpb = @ptrCast(buf);

        // Check boot signature.
        if (!std.mem.eql(u8, &bpb.fil_sys_type, fat32_signature)) {
            log.err("Invalid FAT32 siagnature: {s}", .{bpb.fil_sys_type});
            return fs.Error.InvalidFilesystem;
        }
        if (bpb.boot_sig != Bpb.valid_boot_sig) {
            log.err("Invalid FAT32 boot signature: 0x{X}", .{bpb.boot_sig});
            return fs.Error.InvalidFilesystem;
        }

        // FAT32 specific validation.
        if (bpb.root_ent_cnt != 0 or bpb.fat_sz16 != 0) {
            log.err("Invalid FAT32 BPB info.", .{});
            return fs.Error.InvalidFilesystem;
        }

        // Check sector size.
        if (bpb.bytes_per_sec != sector_size) {
            log.err("Unsupported sector size: {d} bytes", .{bpb.bytes_per_sec});
            return fs.Error.InvalidFilesystem;
        }

        var info = BpbInfo{
            .sec_per_clus = bpb.sec_per_clus,
            .rsvd_sec_cnt = bpb.rsvd_sec_cnt,
            .num_fats = bpb.num_fats,
            .fat_sz32 = bpb.fat_sz32,
            .root_clus = bpb.root_clus,
            .label = undefined,
        };
        @memcpy(&info.label, &bpb.vol_lab);
        return info;
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
const log = std.log.scoped(.fat32);
const Allocator = std.mem.Allocator;
const common = @import("common");
const bits = common.bits;
const block = common.block;
const rtt = common.rtt;
const urd = @import("urthr");
const fs = urd.fs;
