//! FAT32 filesystem implementation.

const Self = @This();

/// Block device backing the FAT32 filesystem.
device: block.Device,
/// BIOS Parameter Block information.
bpb: BpbInfo,
/// Root directory inode.
root: *InodeImpl,
/// Lock to protect FAT32 entries and directory entries.
lock: SpinLock = .{},
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
};

fn fsGetLabel(ctx: *const anyopaque, allocator: Allocator) fs.Error![]const u8 {
    const self: *const Self = @ptrCast(@alignCast(ctx));
    return allocator.dupe(u8, self.bpb.label[0..]);
}

// =============================================================
// Inode Interface
// =============================================================

const inode_vtable = fs.Inode.Ops{
    .lookup = &ilookup,
    .create = &icreate,
    .unlink = &iunlink,
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
    /// Whether the on-disk directory entry has been removed.
    ///
    /// Set by `iunlink`.
    /// The cluster chain is only freed once this inode's refcount reaches zero
    /// so files that are still open when unlinked remain readable until closed.
    unlinked: bool = false,

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

    while (try iter.next(self.allocator)) |result| {
        defer result.deinit(self.allocator);

        if (std.ascii.eqlIgnoreCase(result.name, name)) {
            const inode = try self.allocator.create(InodeImpl);
            errdefer self.allocator.destroy(inode);

            inode.* = .{
                .common = .{
                    .number = result.pos.toInodeNumber(),
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
///
/// If the inode was unlinked, the cluster chain holding its data is freed here.
fn ideinit(inode: *fs.Inode) void {
    const ctx = InodeImpl.from(inode);

    if (ctx.unlinked) switch (inode.ftype) {
        .regular => ctx.fat32.freeCluster(ctx.cluster) catch |err| {
            log.err("Failed to free cluster chain of unlinked file: {t}", .{err});
        },
        .directory => urd.unimplemented("ideinit: directory"),
    };

    ctx.fat32.allocator.destroy(ctx);
}

/// Remove the directory entry under `dir` that refers to `child`.
///
/// Only marks the on-disk directory entry as deleted.
/// The cluster chain is released later in `ideinit` once `child`'s refcount reaches zero,
/// so a file that is still open remains readable after this call.
fn iunlink(dir: *fs.Inode, child: *fs.Inode) fs.Error!void {
    rtt.expectEqual(.directory, dir.ftype);

    const ctx = InodeImpl.from(child);
    const self = ctx.fat32;
    rtt.expectEqual(.regular, ctx.common.ftype);

    self.lock.lock();
    defer self.lock.unlock();

    const pos = Position.fromInodeNumber(child.number);
    var buf: [sector_size]u8 = undefined;
    try self.device.readBlock(pos.sector, &buf);

    const ent: *DirEntry = @ptrCast(@alignCast(&buf[pos.offset]));
    ent.markDeleted();
    try self.device.writeBlock(pos.sector, &buf);

    ctx.unlinked = true;
}

/// Create a new file or directory under a directory inode.
fn icreate(dir: *fs.Inode, name: []const u8, ftype: fs.FileType, _: Allocator) fs.Error!*fs.Inode {
    const ctx = InodeImpl.from(dir);
    const self = ctx.fat32;

    if (!isFitSfn(name)) {
        log.err("Creation of file with LFN not supported: {s}", .{name});
        return fs.Error.Unsupported;
    }

    self.lock.lock();
    defer self.lock.unlock();

    // Allocate a new cluster for the file.
    const clus = try self.allocateCluster(null);
    errdefer self.freeCluster(clus) catch unreachable;

    // Find or create a directory entry slot.
    const entpos = try self.findDirSlot(
        ctx.cluster,
        1,
        .create,
    ) orelse return fs.Error.NoSpace;

    // Initialize the new inode.
    const inode = try self.allocator.create(InodeImpl);
    errdefer self.allocator.destroy(inode);

    // Write the directory entry to the disk.
    var buf: [sector_size]u8 = undefined;
    try self.device.readBlock(entpos.sector, &buf);
    {
        const attr = DirEntry.Attributes{
            .read_only = false,
            .hidden = false,
            .system = false,
            .volume_id = false,
            .directory = (ftype == .directory),
            .archive = true,
        };
        const ent: *DirEntry = @ptrCast(@alignCast(&buf[entpos.offset]));
        ent.* = std.mem.zeroInit(DirEntry, .{
            .attr = attr,
            .first_cluster_low = bits.extract(u16, clus, 0),
            .first_cluster_high = bits.extract(u16, clus, 16),
            .file_size = 0,
        });
        // Timestamp
        writeTimeFields(ent);
        // Name
        // TODO: support LFN.
        writeSfn(ent, name);
    }
    try self.device.writeBlock(entpos.sector, &buf);

    // Construct inode.
    inode.* = .{
        .common = .{
            .number = entpos.toInodeNumber(),
            .size = 0,
            .ftype = ftype,
            .iops = inode_vtable,
            .fops = file_vtable,
        },
        .fat32 = self,
        .cluster = clus,
    };
    inode.common.ref();

    return &inode.common;
}

/// Unique identifier for a position within a disk.
const Position = struct {
    /// Sector number.
    sector: usize,
    /// Offset in bytes within the sector.
    offset: usize,

    /// Calculate inode number.
    ///
    /// FAT32 does not have a real inode number.
    /// So we synthesize a unique number for each file based on its directory entry position.
    fn toInodeNumber(self: Position) u64 {
        const index_offset: u8 = @intCast(self.offset / @sizeOf(DirEntry));
        const sector: u64 = @as(u56, @truncate(self.sector));
        return (sector << 8) + index_offset;
    }

    /// Recover position from inode number.
    fn fromInodeNumber(inum: fs.Inode.Number) Position {
        const index_offset: usize = @intCast(inum & 0xFF);
        return .{
            .sector = @intCast(inum >> 8),
            .offset = index_offset * @sizeOf(DirEntry),
        };
    }
};

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
        pos: Position,

        pub fn deinit(self: *const Result, allocator: Allocator) void {
            allocator.free(self.name);
            allocator.destroy(self.entry);
        }
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
                @memcpy(buf, self.lfn.buf[0..buf.len]);
                break :blk buf;
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
        return std.ascii.lowerString(name, buf[0..len]);
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
    .open = fopen,
    .iterate = fiterate,
    .read = fread,
    .write = fwrite,
    .close = fclose,
    .poll = fpoll,
};

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

const FileImpl = struct {
    /// FAT32 filesystem this file belongs to.
    fat32: *Self,
    /// Starting cluster of the file.
    start_cluster: Cluster,

    pub fn from(file: *fs.File) *FileImpl {
        return @ptrCast(@alignCast(file.ctx));
    }
};

/// Release filesystem-specific resources associated with the file context.
fn fclose(ctx: *anyopaque, allocator: Allocator) void {
    const file: *FileImpl = @ptrCast(@alignCast(ctx));
    allocator.destroy(file);
}

/// Check I/O readiness of the file.
fn fpoll(file: *fs.File) fs.Error!fs.PollResult {
    return switch (file.getType()) {
        .regular => .{ .events = .{
            .in = true,
            .out = true,
        } },
        .directory => .{ .events = .none },
    };
}

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
        defer result.deinit(allocator);

        iter.offset = diter.consumed;
        return .{
            .name = try allocator.dupe(u8, result.name),
            .inum = result.pos.toInodeNumber(),
            .type = if (result.entry.attr.directory) .directory else .regular,
        };
    } else return null;
}

/// Read data from a regular file.
fn fread(file: *fs.File, buf: []u8, offset: usize) fs.Error!usize {
    const ctx = FileImpl.from(file);

    const file_size = file.path.dentry.inode.size;
    if (offset >= file_size) return 0;

    const fat32 = ctx.fat32;
    const bytes_per_cluster = @as(u64, fat32.bpb.sec_per_clus) * sector_size;

    // Seek to the cluster that contains `offset`.
    var clus = ctx.start_cluster; // cluster number of the current position in the file
    var clus_file_offset: u64 = 0; // offset of the current cluster in the file
    while (clus_file_offset + bytes_per_cluster <= offset) : (clus_file_offset += bytes_per_cluster) {
        clus = try fat32.getNextCluster(clus) orelse return fs.Error.CorruptedData;
    }

    // Clamp the read to the remaining file bytes.
    const remaining = file_size - offset;
    const read_buf = buf[0..@min(buf.len, remaining)];

    // Read sector by sector, copying into the caller's buffer.
    var bytes_read: usize = 0;
    var cur_offset = offset;
    var cur_clus = clus;
    var cur_clus_file_offset = clus_file_offset;

    while (bytes_read < read_buf.len) {
        const offset_in_clus = cur_offset - cur_clus_file_offset;
        const sector_in_clus = offset_in_clus / sector_size;
        const offset_in_sec = offset_in_clus % sector_size;

        const lba = fat32.clusterToLba(cur_clus) + sector_in_clus;
        var sec_buf: [sector_size]u8 = undefined;
        try fat32.device.readBlock(lba, &sec_buf);

        const to_copy = @min(sector_size - offset_in_sec, read_buf.len - bytes_read);
        @memcpy(read_buf[bytes_read..][0..to_copy], sec_buf[offset_in_sec..][0..to_copy]);

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

/// Write data to a regular file.
///
/// Extend the file size if necessary.
/// If `offset` is beyond the current EOF, the gap is zero-filled.
fn fwrite(file: *fs.File, buf: []const u8, offset: usize) fs.Error!usize {
    const ctx = FileImpl.from(file);
    const fat32 = ctx.fat32;
    const inode = file.path.dentry.inode;
    const bytes_per_cluster = @as(u64, fat32.bpb.sec_per_clus) * sector_size;

    if (buf.len == 0) return 0;

    fat32.lock.lock();
    defer fat32.lock.unlock();

    const old_size = inode.size;
    const dst_start = @min(offset, old_size);
    const zero_len = offset - dst_start;
    const total_len = zero_len + buf.len;

    // Seek to the cluster that contains `dst_start`.
    var clus = ctx.start_cluster; // cluster number of the current position in the file
    var clus_file_offset: u64 = 0; // offset of the current cluster in the file
    while (clus_file_offset + bytes_per_cluster <= dst_start) : (clus_file_offset += bytes_per_cluster) {
        clus = try fat32.getNextCluster(clus) orelse return fs.Error.CorruptedData;
    }

    // Write sector by sector, zero-filling the gap or copying data.
    var written: u64 = 0;
    var cur_offset = dst_start;
    var cur_clus = clus;
    var cur_clus_file_offset = clus_file_offset;

    while (written < total_len) {
        const offset_in_clus = cur_offset - cur_clus_file_offset;
        const sector_in_clus = offset_in_clus / sector_size;
        const offset_in_sec = offset_in_clus % sector_size;

        const lba = fat32.clusterToLba(cur_clus) + sector_in_clus;
        const to_write = @min(sector_size - offset_in_sec, total_len - written);

        // Read-modify-write unless we're overwriting the whole sector.
        var sec_buf: [sector_size]u8 = undefined;
        if (offset_in_sec != 0 or to_write < sector_size) {
            try fat32.device.readBlock(lba, &sec_buf);
        }

        if (written < zero_len) {
            const zero_copy = @min(to_write, zero_len - written);
            @memset(sec_buf[offset_in_sec..][0..zero_copy], 0);
            if (zero_copy < to_write) {
                @memcpy(sec_buf[offset_in_sec + zero_copy ..][0 .. to_write - zero_copy], buf[0 .. to_write - zero_copy]);
            }
        } else {
            const data_off = written - zero_len;
            @memcpy(sec_buf[offset_in_sec..][0..to_write], buf[data_off..][0..to_write]);
        }

        try fat32.device.writeBlock(lba, &sec_buf);

        written += to_write;
        cur_offset += to_write;

        // If we crossed a cluster boundary, follow or extend the FAT chain.
        if (cur_offset - cur_clus_file_offset >= bytes_per_cluster) {
            rtt.expect(cur_offset == cur_clus_file_offset + bytes_per_cluster);
            cur_clus = try fat32.getNextCluster(cur_clus) orelse try fat32.allocateCluster(cur_clus);
            cur_clus_file_offset += bytes_per_cluster;
        }
    }

    // Update the directory entry.
    const new_size = offset + buf.len;
    if (new_size > old_size) {
        inode.size = new_size;
        try fat32.updateDirEntrySize(inode.number, new_size);
    }

    return buf.len;
}

/// Update the file size field of the on-disk directory entry.
///
/// Caller must hold `self.lock`.
fn updateDirEntrySize(self: *Self, inum: fs.Inode.Number, new_size: usize) fs.Error!void {
    const pos = Position.fromInodeNumber(inum);

    var buf: [sector_size]u8 = undefined;
    try self.device.readBlock(pos.sector, &buf);

    const ent: *DirEntry = @ptrCast(@alignCast(&buf[pos.offset]));
    ent.file_size = @intCast(new_size);

    try self.device.writeBlock(pos.sector, &buf);
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

const FindOption = enum {
    /// Returns `nulli if no available slot is found.
    none,
    /// Allocate a new cluster if no available slot is found.
    create,
};

/// Find an deleted or free directory entry slot in the given directory cluster chain.
///
/// When `opt` is `.create`, allocate a new cluster if no available slot is found.
///
/// Caller must ensure that the given cluster is a part of a directory.
fn findDirSlot(self: *Self, start: Cluster, count: usize, opt: FindOption) fs.Error!?Position {
    var clus = start;
    var buf: [sector_size]u8 = undefined;

    var avail_start: Position = undefined;
    var avail_count: usize = 0;
    // Iterate through the cluster chain.
    while (true) {
        // Iterate through all sectors in the cluster.
        const clus_lba = self.clusterToLba(clus);
        for (0..self.bpb.sec_per_clus) |sec| {
            const lba = clus_lba + sec;
            try self.device.readBlock(lba, &buf);

            // Iterate through all directory entries in the sector.
            for (clus2dirents(&buf), 0..) |ent, i| {
                if (ent.isFree() or ent.isDeleted()) {
                    if (avail_count == 0) {
                        avail_start = .{
                            .sector = lba,
                            .offset = i * @sizeOf(DirEntry),
                        };
                    }
                    avail_count += 1;
                } else {
                    avail_count = 0;
                }

                if (avail_count == count) {
                    return avail_start;
                }
            }
        }

        clus = try self.getNextCluster(clus) orelse break;
    }

    // Available consecutive slots not found.
    if (opt == .none) {
        return null;
    }

    // Create a new cluster for new directory entries.
    @memset(&buf, 0);
    var cur = clus;
    while (avail_count < count) {
        const new = try self.allocateCluster(cur);
        const lba = self.clusterToLba(new);
        for (0..self.bpb.sec_per_clus) |sec| {
            try self.device.writeBlock(lba + sec, &buf);
        }

        if (avail_count == 0) {
            avail_start = .{
                .sector = lba,
                .offset = 0,
            };
        }
        avail_count += self.bpb.sec_per_clus * (sector_size / @sizeOf(DirEntry));

        cur = new;
    }

    return avail_start;
}

/// Find a free cluster, mark it as end-of-chain, and optionally link it to the chain.
///
/// Returns the new cluster number.
fn allocateCluster(self: *Self, prev: ?Cluster) fs.Error!Cluster {
    const total_fat_entries = @as(u64, self.bpb.fat_sz32) * sector_size / fat_entry_size;
    const root_clus = self.bpb.root_clus;

    var buf: [sector_size]u8 = undefined;
    var current_fat_sector: u64 = std.math.maxInt(u64);

    // Iterate through the FATs to find a free cluster.
    var clus = root_clus;
    while (clus < total_fat_entries) : (clus += 1) {
        const fat_offset = clus * fat_entry_size;
        const fat_sector = @as(u64, self.bpb.rsvd_sec_cnt) + fat_offset / sector_size;
        const entry_offset = fat_offset % sector_size;

        if (fat_sector != current_fat_sector) {
            try self.device.readBlock(fat_sector, &buf);
            current_fat_sector = fat_sector;
        }

        const entry = std.mem.readInt(
            u32,
            buf[entry_offset..][0..fat_entry_size],
            .little,
        ) & fat_mask;
        if (entry == fat_free_cluster) {
            // Mark as EOC.
            try self.setFatEntry(clus, fat_eoc_min);
            // Link to previous cluster if provided.
            if (prev) |p| try self.setFatEntry(p, clus);

            return clus;
        }
    }

    return fs.Error.NoSpace;
}

/// Free the cluster chain starting from the given cluster.
fn freeCluster(self: *Self, clus: Cluster) fs.Error!void {
    var current = clus;
    while (true) {
        const next = try self.getNextCluster(current);
        try self.setFatEntry(current, fat_free_cluster);
        current = next orelse break;
    }
}

/// Update a FAT entry for the given cluster across all FAT copies.
fn setFatEntry(self: *Self, cluster: Cluster, value: u32) fs.Error!void {
    rtt.expectEqual(0, value & ~fat_mask);
    rtt.expect(cluster >= self.bpb.root_clus);

    const offset = @as(u64, cluster) * fat_entry_size;
    const sec_offset = offset / sector_size;
    const entry_offset = offset % sector_size;
    const first_fat_sec = @as(u64, self.bpb.rsvd_sec_cnt) + sec_offset;

    var buf: [sector_size]u8 = undefined;
    try self.device.readBlock(first_fat_sec, &buf);

    // Write the new FAT entry value to the temporary buffer.
    const old = std.mem.readInt(
        u32,
        buf[entry_offset..][0..fat_entry_size],
        .little,
    );
    const new = (old & ~fat_mask) | (value & fat_mask);
    std.mem.writeInt(
        u32,
        buf[entry_offset..][0..fat_entry_size],
        new,
        .little,
    );

    // Write the updated FAT entry to all FAT copies.
    for (0..self.bpb.num_fats) |i| {
        const fat_sector = @as(u64, self.bpb.rsvd_sec_cnt) +
            i * self.bpb.fat_sz32 + sec_offset;
        try self.device.writeBlock(fat_sector, &buf);
    }
}

/// Convert a cluster data to a directory entry slice.
fn clus2dirents(buf: []const u8) []const DirEntry {
    rtt.expectEqual(0, buf.len % @sizeOf(DirEntry));
    const ptr: [*]const DirEntry = @ptrCast(@alignCast(buf.ptr));
    return ptr[0 .. buf.len / @sizeOf(DirEntry)];
}

/// Fill the timestamp fields of a directory entry with the current time.
fn writeTimeFields(dirent: *DirEntry) void {
    // TODO: implement
    _ = dirent;
}

/// Write the SFN to the directory entry.
/// TODO: make this a method of `DirEntry`.
fn writeSfn(dirent: *DirEntry, name: []const u8) void {
    rtt.expect(isFitSfn(name));

    const stem = sfnGetStem(name);
    const ext = sfnGetExt(name);
    const dst_stem = dirent.name[0..8];
    const dst_ext = dirent.name[8..11];
    @memset(&dirent.name, ' ');
    @memcpy(dst_stem[0..stem.len], stem);
    @memcpy(dst_ext[0..ext.len], ext);
}

/// Extract the stem part of a name for SFN.
///
/// - `foo.txt` -> `foo`
/// - `foo` -> `foo`
/// - `foo.` -> `foo.`
/// - `.txt` -> ``
fn sfnGetStem(name: []const u8) []const u8 {
    const stem = std.fs.path.stem(name);
    const ext_dot = std.fs.path.extension(name);
    return if (ext_dot.len == 1) name else stem;
}

/// Extract the extension part of a name for SFN.
///
/// - `foo.txt` -> `txt`
/// - `foo` -> ``
/// - `foo.` -> ``
/// - `.txt` -> `txt`
fn sfnGetExt(name: []const u8) []const u8 {
    const ext_dot = std.fs.path.extension(name);
    return if (ext_dot.len <= 1) "" else ext_dot[1..];
}

/// Check if the given name can be represented as a SFN.
fn isFitSfn(name: []const u8) bool {
    const stem = sfnGetStem(name);
    const ext = sfnGetExt(name);
    if (stem.len == 0 or stem.len > 8) return false;
    if (ext.len > 3) return false;

    for (stem) |c| {
        if (!std.ascii.isAlphanumeric(c)) return false;
    }
    for (ext) |c| {
        if (!std.ascii.isAlphanumeric(c)) return false;
    }

    return true;
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
const fat_mask: u32 = 0x0FFF_FFFF;
/// Minimum value indicating end-of-cluster-chain.
const fat_eoc_min: u32 = 0x0FFFFFF8;
/// Bad cluster marker.
const fat_bad_cluster: u32 = 0x0FFF_FFF7;
/// Free cluster marker.
const fat_free_cluster: u32 = 0x0000_0000;

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

    comptime {
        urd.comptimeAssert(32 * 8 == @bitSizeOf(DirEntry), "Invalid size of DirEntry", .{});
    }

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

    /// Marker representing a deleted directory entry name.
    const deleted_marker: u8 = 0xE5;

    /// Check if the entry is deleted.
    fn isDeleted(self: DirEntry) bool {
        return self.name[0] == deleted_marker;
    }

    /// Mark the entry as deleted.
    fn markDeleted(self: *DirEntry) void {
        self.name[0] = deleted_marker;
    }

    /// Get the starting cluster number of the entry.
    fn clusterNumber(self: DirEntry) u32 {
        return bits.concat(u32, self.first_cluster_high, self.first_cluster_low);
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
const sync = urd.sync;
const SpinLock = sync.SpinLock;
