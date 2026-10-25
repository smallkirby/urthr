//! FAT32 filesystem implementation.

const Self = @This();

/// Block device backing the FAT32 filesystem.
device: block.Device,
/// BIOS Parameter Block information.
bpb: BpbInfo,
/// Root directory inode.
root: *InodeImpl,
/// Hint of the next free cluster to start searching from.
free_clus_hint: Cluster,

/// Lock to protect FAT32 entries and directory entries.
lock: Mutex = .{},
/// Memory allocator.
allocator: Allocator,
/// Write-back cache for FAT sectors.
cache: SectorCache,
/// Incremented whenever any file's cluster chain is shortened.
chain_gen: u64 = 0,
/// Indexes of the directory entries by the first cluster of the directory.
dindexes: std.AutoHashMapUnmanaged(Cluster, *Dindex) = .empty,

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
    try device.readBlocks(0, &buf);

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

    // Allocate buffer for sector cache.
    const cache_buf = try allocator.alloc(u8, SectorCache.nslots * sector_size);
    errdefer allocator.free(cache_buf);
    const cache_slots = try allocator.alloc(SectorCache.Slot, SectorCache.nslots);
    errdefer allocator.free(cache_slots);
    @memset(cache_slots, .{});

    self.* = .{
        .device = device,
        .bpb = bpb,
        .allocator = allocator,
        .root = root,
        .free_clus_hint = bpb.root_clus,
        .cache = .{ .slots = cache_slots, .data = cache_buf },
    };
    return self;
}

/// Get the filesystem interface.
pub fn filesystem(self: *Self) fs.FileSystem {
    return .{
        .ptr = self,
        .vtable = &fs_vtable,
        .root = &self.root.common,
        .case_insensitive = true,
    };
}

// =============================================================
// Filesystem Interface
// =============================================================

const fs_vtable = fs.FileSystem.Vtable{
    .getLabel = fsGetLabel,
    .sync = fsSync,
};

fn fsGetLabel(ctx: *const anyopaque, allocator: Allocator) fs.Error![]const u8 {
    const self: *const Self = @ptrCast(@alignCast(ctx));
    return allocator.dupe(u8, self.bpb.label[0..]);
}

fn fsSync(ctx: *anyopaque) fs.Error!void {
    const self: *Self = @ptrCast(@alignCast(ctx));

    self.lock.lock();
    defer self.lock.unlock();

    try self.cache.flushAll(self);
    return self.device.flush() catch fs.Error.IoError;
}

// =============================================================
// Directory Index
// =============================================================

/// Size of the buffer to hold an entry name in UTF-8.
const name_buf_len = LongNameEntry.max_name_len * 3;

/// Index from a lower-cased name to the position of the entry in a directory.
///
/// To efficiently look up directory entries by their lower-cased names
/// without the need to scan the entire directory entries.
const Dindex = struct {
    /// Number of hash buckets.
    const num_buckets = 1024;

    /// Hash buckets for the entries.
    buckets: [num_buckets]?*Entry = @splat(null),

    /// Indexed entry.
    const Entry = struct {
        /// Next entry in the same bucket.
        next: ?*Entry,
        /// Position of the SFN entry.
        pos: Position,
        /// Lower-cased name.
        key: Key,

        /// The maximum length of the name that can be stored inline.
        const inline_name_limit = 32;

        const Key = union(enum) {
            /// Name that is small enough to be stored inline.
            short: struct { len: u8, buf: [inline_name_limit]u8 },
            /// Name that is too long. Owned by the entry.
            long: []const u8,
        };

        /// Get the name of the entry.
        fn name(self: *const Entry) []const u8 {
            return switch (self.key) {
                .short => |*s| s.buf[0..s.len],
                .long => |l| l,
            };
        }

        /// Deinitialize the entry and free its resources.
        fn deinit(self: *Entry, allocator: Allocator) void {
            if (self.key == .long) allocator.free(self.key.long);
            allocator.destroy(self);
        }
    };

    /// Deinitialize the directory index and free its resources.
    fn deinit(self: *Dindex, allocator: Allocator) void {
        for (&self.buckets) |*head| {
            while (head.*) |e| {
                head.* = e.next;
                e.deinit(allocator);
            }
        }
    }

    /// Get the position of the entry indexed by the given key.
    ///
    /// Returns null if the entry is not found.
    fn get(self: *const Dindex, key: []const u8) ?Position {
        var keybuf: [name_buf_len]u8 = undefined;
        const lowered = std.ascii.lowerString(&keybuf, key);
        return self.getLowered(lowered);
    }

    /// Get the position of the entry indexed by the given key.
    ///
    /// The key must be lower-cased.
    ///
    /// Returns null if the entry is not found.
    fn getLowered(self: *const Dindex, key: []const u8) ?Position {
        var cur = self.buckets[bucketOf(key)];
        while (cur) |e| : (cur = e.next) {
            if (std.mem.eql(u8, e.name(), key)) return e.pos;
        } else return null;
    }

    /// Register the entry at `pos`.
    ///
    /// The key must be lower-cased.
    ///
    /// If the name already exists, the first one is kept.
    fn register(self: *Dindex, allocator: Allocator, key: []const u8, pos: Position) Allocator.Error!void {
        if (self.getLowered(key) != null) return;

        const entry = try allocator.create(Entry);
        errdefer allocator.destroy(entry);
        entry.* = .{
            .next = null,
            .pos = pos,
            .key = undefined,
        };
        if (key.len <= Entry.inline_name_limit) {
            entry.key = .{ .short = .{
                .len = @intCast(key.len),
                .buf = undefined,
            } };
            @memcpy(entry.key.short.buf[0..key.len], key);
        } else {
            entry.key = .{ .long = try allocator.dupe(u8, key) };
        }

        const head = &self.buckets[bucketOf(key)];
        entry.next = head.*;
        head.* = entry;
    }

    /// Unregister the entry of the name at `pos`.
    ///
    /// Returns whether the entry was registered.
    fn remove(self: *Dindex, allocator: Allocator, name: []const u8, pos: Position) bool {
        if (name.len > name_buf_len) return false;

        var keybuf: [name_buf_len]u8 = undefined;
        const key = std.ascii.lowerString(&keybuf, name);

        var link = &self.buckets[bucketOf(key)];
        while (link.*) |e| : (link = &e.next) {
            if (e.pos.sector != pos.sector or e.pos.offset != pos.offset) continue;
            if (!std.mem.eql(u8, e.name(), key)) continue;

            link.* = e.next;
            e.deinit(allocator);
            return true;
        }
        return false;
    }

    /// Get the hash bucket index for the given key.
    fn bucketOf(key: []const u8) usize {
        return std.hash.Wyhash.hash(0, key) & (num_buckets - 1);
    }
};

/// Discard the dindex of this directory that starts at the cluster.
fn dropDindex(self: *Self, cluster: Cluster) void {
    const kv = self.dindexes.fetchRemove(cluster) orelse return;
    kv.value.deinit(self.allocator);
    self.allocator.destroy(kv.value);
}

// =============================================================
// Inode Interface
// =============================================================

const inode_vtable = fs.Inode.Ops{
    .lookup = &ilookup,
    .create = &icreate,
    .unlink = &iunlink,
    .rmdir = &irmdir,
    .chmod = &ichmod,
    .rename = &irename,
    .utimes = &iutimes,
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

    /// Get the dindex for this directory.
    ///
    /// If the dindex is not registered, new dindex is constructed and registered.
    fn getOrSpawnDindex(self: *InodeImpl) fs.Error!*Dindex {
        rtt.expectEqual(.directory, self.common.ftype);

        // Check if the dindex for this cluster already exists.
        if (self.fat32.dindexes.get(self.cluster)) |didx| {
            return didx;
        }

        // Create a new dindex.
        const allocator = self.fat32.allocator;
        const idx = try allocator.create(Dindex);
        errdefer allocator.destroy(idx);
        idx.* = .{};
        errdefer idx.deinit(allocator);

        // Collect all directory entries into the dindex.
        var keybuf: [name_buf_len]u8 = undefined;
        var iter = DirIterator{
            .fat32 = self.fat32,
            .cluster = self.cluster,
        };
        while (try iter.next(allocator)) |result| {
            defer result.deinit(allocator);
            try idx.register(
                allocator,
                std.ascii.lowerString(&keybuf, result.name),
                result.pos,
            );
        }

        // Register the dindex in the map.
        try self.fat32.dindexes.put(allocator, self.cluster, idx);

        return idx;
    }

    /// Get the dindex of the directory.
    ///
    /// Returns null if the dindex is not registered.
    fn tryGetDindex(self: *InodeImpl) ?*Dindex {
        rtt.expectEqual(.directory, self.common.ftype);
        return self.fat32.dindexes.get(self.cluster);
    }

    /// Discard the dindex of the directory.
    fn dropDindex(self: *InodeImpl) void {
        rtt.expectEqual(.directory, self.common.ftype);
        self.fat32.dropDindex(self.cluster);
    }
};

/// Lookup an inode by its name in a directory inode.
fn ilookup(dir: *fs.Inode, name: []const u8) fs.Error!?*fs.Inode {
    rtt.expect(dir.ftype == .directory);

    if (name.len > name_buf_len) {
        return null; // name too long
    }

    const ctx = InodeImpl.from(dir);
    const self = ctx.fat32;

    self.lock.lock();
    defer self.lock.unlock();

    // Get the position of the entry using dindex.
    const didx = try ctx.getOrSpawnDindex();
    const pos = didx.get(name) orelse return null;

    // Read a whole sector to get the directory entry.
    var buf: [sector_size]u8 = undefined;
    try self.readBlocks(pos.sector, &buf);
    const entry: *const DirEntry = @ptrCast(@alignCast(&buf[pos.offset]));

    // Construct a new inode for the found directory entry.
    const inode = try self.allocator.create(InodeImpl);
    errdefer self.allocator.destroy(inode);

    const mode: fs.FileMode = if (entry.attr.read_only) .{
        .other = .rx,
        .group = .rx,
        .user = .rx,
    } else .{};
    inode.* = .{
        .common = .{
            .number = pos.toInodeNumber(),
            .size = entry.file_size,
            .ftype = if (entry.attr.directory) .directory else .regular,
            .mode = mode,
            .times = readTimeFields(entry),
            .iops = inode_vtable,
            .fops = file_vtable,
            .cacheable = true,
        },
        .fat32 = self,
        .cluster = entry.clusterNumber(),
    };

    return &inode.common;
}

/// Release resources associated with an inode.
///
/// If the inode was unlinked, the cluster chain holding its data is freed here.
fn ideinit(inode: *fs.Inode) void {
    const ctx = InodeImpl.from(inode);

    if (ctx.unlinked) switch (inode.ftype) {
        .regular => {
            ctx.fat32.lock.lock();
            defer ctx.fat32.lock.unlock();
            defer ctx.fat32.flushCache();

            ctx.fat32.freeCluster(ctx.cluster) catch |err| {
                log.err("Failed to free cluster chain of unlinked file: {t}", .{err});
            };
        },

        .directory => {
            ctx.fat32.lock.lock();
            defer ctx.fat32.lock.unlock();
            defer ctx.fat32.flushCache();

            ctx.dropDindex();
            ctx.fat32.freeCluster(ctx.cluster) catch |err| {
                log.err("Failed to free cluster chain of unlinked file: {t}", .{err});
            };
        },

        .symlink, .socket => unreachable,
    };

    ctx.fat32.allocator.destroy(ctx);
}

/// Remove the directory entry under `dir` that refers to `child`.
///
/// Only marks the on-disk directory entry as deleted.
/// The cluster chain is released later in `ideinit` once `child`'s refcount reaches zero,
/// so a file that is still open remains readable after this call.
fn iunlink(dir: *fs.Inode, dchild: *fs.Dentry) fs.Error!void {
    const child = dchild.getInode();
    rtt.expectEqual(.directory, dir.ftype);
    rtt.expectEqual(.regular, child.ftype);
    try markEntryDeleted(dir, child, dchild.name);
}

/// Remove the directory entry for the empty subdirectory.
///
/// Only marks the on-disk directory entry as deleted.
/// The cluster chain is released later in `ideinit` once the refcount reaches zero.
fn irmdir(dir: *fs.Inode, dchild: *fs.Dentry) fs.Error!void {
    const child = dchild.getInode();
    rtt.expectEqual(.directory, dir.ftype);
    rtt.expectEqual(.directory, child.ftype);
    try markEntryDeleted(dir, child, dchild.name);
}

/// Mark the on-disk directory entry as deleted along with any LFN entries preceding it.
fn markEntryDeleted(dir: *fs.Inode, child: *fs.Inode, name: []const u8) fs.Error!void {
    const ctx = InodeImpl.from(child);
    const self = ctx.fat32;

    self.lock.lock();
    defer self.lock.unlock();
    defer self.flushCache();

    const pos = Position.fromInodeNumber(child.number);
    var buf: [sector_size]u8 = undefined;
    try self.readBlocks(pos.sector, &buf);

    const ent: *DirEntry = @ptrCast(@alignCast(&buf[pos.offset]));
    const sfn = ent.name;

    // Mark the directory entry as deleted on disk.
    ent.markDeleted();
    try self.writeBlocks(pos.sector, &buf);

    // Remove the entry from the dindex.
    const dir_inode = InodeImpl.from(dir);
    if (dir_inode.tryGetDindex()) |didx| {
        if (!didx.remove(self.allocator, name, pos)) {
            log.warn("Failed to remove entry from dindex: {s}", .{name});
            dir_inode.dropDindex();
        }
    }

    // Delete any preceding LFN entries.
    try self.deletePrecedingLfnEntries(dir_inode.cluster, pos, &sfn);

    ctx.unlinked = true;
}

/// Update the on-disk read-only attribute to reflect the requested mode.
fn ichmod(inode: *fs.Inode, mode: fs.FileMode) fs.Error!void {
    const ctx = InodeImpl.from(inode);
    const self = ctx.fat32;

    if (!self.hasDirEntry(inode)) {
        return;
    }

    self.lock.lock();
    defer self.lock.unlock();
    defer self.flushCache();

    const pos = Position.fromInodeNumber(inode.number);
    var buf: [sector_size]u8 = undefined;
    try self.readBlocks(pos.sector, &buf);

    const ent: *DirEntry = @ptrCast(@alignCast(&buf[pos.offset]));
    ent.attr.read_only = !isWritable(mode);
    try self.writeBlocks(pos.sector, &buf);
}

/// Persist the file's timestamps into its on-disk directory entry.
fn iutimes(inode: *fs.Inode) fs.Error!void {
    const ctx = InodeImpl.from(inode);
    const self = ctx.fat32;

    if (!self.hasDirEntry(inode)) {
        return;
    }

    self.lock.lock();
    defer self.lock.unlock();
    defer self.flushCache();

    const pos = Position.fromInodeNumber(inode.number);
    var buf: [sector_size]u8 = undefined;
    try self.readBlocks(pos.sector, &buf);

    const ent: *DirEntry = @ptrCast(@alignCast(&buf[pos.offset]));
    writeTimeFields(ent, inode.times);
    try self.writeBlocks(pos.sector, &buf);
}

/// Create a new file or directory under a directory inode.
fn icreate(dir: *fs.Inode, name: []const u8, ftype: fs.FileType, mode: fs.FileMode, _: Allocator) fs.Error!*fs.Inode {
    const ctx = InodeImpl.from(dir);
    const self = ctx.fat32;

    if (name.len > LongNameEntry.max_name_len) {
        return fs.Error.InvalidArgument;
    }

    self.lock.lock();
    defer self.lock.unlock();
    defer self.flushCache();

    // Allocate a new cluster for the file.
    const clus = try self.allocateCluster(null);
    errdefer self.freeCluster(clus) catch unreachable;

    // Clear the cluster for directory.
    if (ftype == .directory) {
        var zero_buf = std.mem.zeroes([sector_size]u8);
        const lba = self.clusterToLba(clus);
        for (0..self.bpb.sec_per_clus) |sec| {
            try self.writeBlocks(lba + sec, &zero_buf);
        }

        // Discard dindex in case the cluster is reused before the old entry is deinit-ed.
        self.dropDindex(clus);
    }

    // Determine the short name converting from UTF-8 to UTF-16.
    const use_lfn = !isFitSfn(name);
    var u16name_buf: [LongNameEntry.max_name_len]u16 = undefined;
    var u16name: []const u16 = &.{};
    if (use_lfn) {
        const n = std.unicode.utf8ToUtf16Le(&u16name_buf, name) catch {
            return fs.Error.InvalidArgument;
        };
        u16name = u16name_buf[0..n];
    }
    const sfn = if (use_lfn)
        try self.genShortName(ctx.cluster, name)
    else
        sfnArray(name);
    const lfn_count = if (use_lfn) lfnEntryCount(u16name.len) else 0;

    // Find or create a directory entry slots.
    const entpos = try self.findDirSlot(
        ctx.cluster,
        lfn_count + 1, // +1 for real directory entry
        .create,
    ) orelse return fs.Error.NoSpace;

    // Build and write the directory entry.
    const attr = DirEntry.Attributes{
        .read_only = !isWritable(mode),
        .hidden = false,
        .system = false,
        .volume_id = false,
        .directory = (ftype == .directory),
        .archive = true,
    };
    var dent = std.mem.zeroInit(DirEntry, .{
        .name = sfn,
        .attr = attr,
        .first_cluster_low = bits.extract(u16, clus, 0),
        .first_cluster_high = bits.extract(u16, clus, 16),
        .file_size = 0,
    });
    const create_times = fs.Times.now();
    writeTimeFields(&dent, create_times);

    // Write the LFN entries followed by the SFN entry.
    var rawents: [LongNameEntry.max_entries + 1][@sizeOf(DirEntry)]u8 = undefined;
    if (use_lfn) {
        var buf: [LongNameEntry.max_entries]LongNameEntry = undefined;
        const lents = buildLfnEntries(
            buf[0..lfn_count],
            u16name,
            computeSfnChecksum(&sfn),
        );
        for (lents, 0..) |ent, i| {
            rawents[i] = std.mem.asBytes(&ent).*;
        }
    }
    rawents[lfn_count] = std.mem.asBytes(&dent).*;
    const sfn_pos = try self.writeDirEntries(
        entpos,
        rawents[0 .. lfn_count + 1],
    );

    // Add this entry to the dindex if exists.
    if (ctx.tryGetDindex()) |idx| {
        var keybuf: [name_buf_len]u8 = undefined;
        const key = if (use_lfn)
            std.ascii.lowerString(&keybuf, name)
        else
            formatSfn(&dent, keybuf[0..sfn_name_buf_len]);

        idx.register(
            self.allocator,
            key,
            sfn_pos,
        ) catch ctx.dropDindex(); // out of memory
    }

    // Initialize the new inode.
    const inode = try self.allocator.create(InodeImpl);
    errdefer self.allocator.destroy(inode);
    inode.* = .{
        .common = .{
            .number = sfn_pos.toInodeNumber(),
            .size = 0,
            .ftype = ftype,
            .mode = mode,
            .times = create_times,
            .iops = inode_vtable,
            .fops = file_vtable,
            .cacheable = true,
        },
        .fat32 = self,
        .cluster = clus,
    };

    return &inode.common;
}

/// Move the directory entry for `child` to `new_name` under `new_dir`,
/// optionally replacing an existing entry `replaced` at the destination.
fn irename(old_dir: *fs.Inode, _: []const u8, child: *fs.Inode, new_dir: *fs.Inode, new_name: []const u8, replaced: ?*fs.Inode) fs.Error!void {
    const self = InodeImpl.from(child).fat32;
    var buf: [sector_size]u8 = undefined;

    if (new_name.len > LongNameEntry.max_name_len) {
        return fs.Error.InvalidArgument;
    }

    self.lock.lock();
    defer self.lock.unlock();
    defer self.flushCache();

    // TODO: should not discard entire indexes.
    InodeImpl.from(old_dir).dropDindex();
    InodeImpl.from(new_dir).dropDindex();

    // Snapshot the existing directory entry.
    const old_pos = Position.fromInodeNumber(child.number);
    try self.readBlocks(old_pos.sector, &buf);
    var ent_data = @as(*const DirEntry, @ptrCast(@alignCast(&buf[old_pos.offset]))).*;
    const old_sfn = ent_data.name;

    // Determine the short name converting from UTF-8 to UTF-16.
    const use_lfn = !isFitSfn(new_name);
    var u16name_buf: [LongNameEntry.max_name_len]u16 = undefined;
    var u16name: []const u16 = &.{};
    if (use_lfn) {
        const n = std.unicode.utf8ToUtf16Le(&u16name_buf, new_name) catch {
            return fs.Error.InvalidArgument;
        };
        u16name = u16name_buf[0..n];
    }
    const new_sfn = if (use_lfn)
        try self.genShortName(InodeImpl.from(new_dir).cluster, new_name)
    else
        sfnArray(new_name);
    ent_data.name = new_sfn;
    const lfn_count = if (use_lfn) lfnEntryCount(u16name.len) else 0;

    // Remove replaced directory entry and any LFN entries preceding it.
    if (replaced) |r| {
        const r_pos = Position.fromInodeNumber(r.number);
        try self.readBlocks(r_pos.sector, &buf);
        const r_ent: *DirEntry = @ptrCast(@alignCast(&buf[r_pos.offset]));
        const r_sfn = r_ent.name;

        // Remove the directory entry.
        r_ent.markDeleted();
        try self.writeBlocks(r_pos.sector, &buf);
        // Remove the preceding LFN entries.
        try self.deletePrecedingLfnEntries(
            InodeImpl.from(new_dir).cluster,
            r_pos,
            &r_sfn,
        );
    }

    // Find or create a directory entry slots.
    const entpos = try self.findDirSlot(
        InodeImpl.from(new_dir).cluster,
        lfn_count + 1, // +1 for real directory entry
        .create,
    ) orelse return fs.Error.NoSpace;

    // Build and write the directory entry.
    var rawents: [LongNameEntry.max_entries + 1][@sizeOf(DirEntry)]u8 = undefined;
    if (use_lfn) {
        var lbuf: [LongNameEntry.max_entries]LongNameEntry = undefined;
        const lents = buildLfnEntries(
            lbuf[0..lfn_count],
            u16name,
            computeSfnChecksum(&new_sfn),
        );
        for (lents, 0..) |ent, i| {
            rawents[i] = std.mem.asBytes(&ent).*;
        }
    }
    rawents[lfn_count] = std.mem.asBytes(&ent_data).*;
    const new_pos = try self.writeDirEntries(
        entpos,
        rawents[0 .. lfn_count + 1],
    );

    // Delete the old entry unless it was reused.
    if (new_pos.sector != old_pos.sector or new_pos.offset != old_pos.offset) {
        try self.readBlocks(old_pos.sector, &buf);
        const old_ent: *DirEntry = @ptrCast(@alignCast(&buf[old_pos.offset]));

        // Remove the old directory entry.
        old_ent.markDeleted();
        try self.writeBlocks(old_pos.sector, &buf);
        // Remove the preceding LFN entries.
        try self.deletePrecedingLfnEntries(InodeImpl.from(old_dir).cluster, old_pos, &old_sfn);
    }

    // Update in-memory inode number.
    child.number = new_pos.toInodeNumber();

    // The replaced inode's cluster chain should be freed once its refcount reaches zero.
    if (replaced) |r| {
        InodeImpl.from(r).unlinked = true;
    }
}

/// Check if the mode includes any write permission for owner, group, or others.
///
/// This workaround is needed since FAT32 has only single read-only attribute.
inline fn isWritable(mode: fs.FileMode) bool {
    return mode.user.write or mode.group.write or mode.other.write;
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
        /// Buffer for collecting long file name UTF-16 code units.
        buf: [LongNameEntry.max_name_len]u16 = undefined,
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
                try self.fat32.readBlocks(lba + sector_in_cluster, &self.buffer);
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
            // A malformed on-disk UTF-16 sequence falls back to the short name too.
            const name = if (self.lfn.isValid(&entry.name))
                std.unicode.utf16LeToUtf8Alloc(allocator, self.lfn.buf[0..self.lfn.len]) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.DanglingSurrogateHalf,
                    error.ExpectedSecondSurrogateHalf,
                    error.UnexpectedSecondSurrogateHalf,
                    => try parseName(entry, allocator),
                }
            else
                try parseName(entry, allocator);
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
        var buf: [sfn_name_buf_len]u8 = undefined;
        return allocator.dupe(u8, formatSfn(entry, &buf));
    }
};

/// Maximum length of the formatted SFN.
const sfn_name_buf_len = 12; // name (8) + dot (1) + extension (3)

/// Format the SFN of the entry in lower-case into the buffer.
fn formatSfn(entry: *const DirEntry, buf: *[sfn_name_buf_len]u8) []const u8 {
    var len: usize = 0;

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

    return std.ascii.lowerString(buf[0..len], buf[0..len]);
}

// =============================================================
// File Interface
// =============================================================

const file_vtable = fs.File.Ops{
    .open = fopen,
    .iterate = fiterate,
    .read = fread,
    .write = fwrite,
    .truncate = ftruncate,
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

/// Pair of cluster number and its offset from the start of the file.
const ClsOff = struct {
    /// Cluster number.
    cluster: Cluster,
    /// Offset of the cluster from the start of the file.
    file_offset: u64,
};

/// Saved position within a directory entry stream.
const DirCursor = struct {
    /// Total bytes consumed from the start of the directory stream.
    consumed: usize,
    /// Cluster the next entry starts in.
    cluster: Cluster,
    /// Byte offset of the next entry within `cluster`.
    offset: usize,
};

const FileImpl = struct {
    /// FAT32 filesystem this file belongs to.
    fat32: *Self,
    /// Starting cluster of the file.
    start_cluster: Cluster,
    /// Cache of the cluster position accessed by the most recent read or write.
    cache: ?ClsOff = null,
    /// Clusters of the file in order.
    ///
    /// Note that this list may not include all clusters.
    /// This chain only includes clusters that have been accessed so far.
    chain: std.ArrayList(Cluster) = .empty,
    /// Chain generation when `chain` was constructed.
    chain_gen: u64 = 0,
    /// Cached directory-stream cursor for sequential iteration.
    dcursor: ?DirCursor = null,

    pub fn from(file: *fs.File) *FileImpl {
        return @ptrCast(@alignCast(file.ctx));
    }

    /// Find the cluster and its file offset that contains the target byte offset within a file.
    ///
    /// Use cached cluster information, fallback to iterating the FAT chain if necessary.
    fn seekCluster(self: *FileImpl, target: u64) fs.Error!ClsOff {
        const fat32 = self.fat32;
        const bytes_per_cluster = @as(u64, fat32.bpb.sec_per_clus) * sector_size;
        const index: usize = @intCast(target / bytes_per_cluster);

        // Discard the chain if any cluster has been freed since it was built.
        if (self.chain_gen != fat32.chain_gen) {
            self.chain.clearRetainingCapacity();
            self.chain_gen = fat32.chain_gen;
        }
        // Set the first cluster if not present in the chain cache.
        if (self.chain.items.len == 0) {
            self.chain.append(fat32.allocator, self.start_cluster) catch {
                return fs.Error.OutOfMemory;
            };
        }

        // Extend the chain until it contains the target cluster.
        while (self.chain.items.len <= index) {
            const last = self.chain.items[self.chain.items.len - 1];
            const next = try fat32.getNextCluster(last) orelse return fs.Error.CorruptedData;
            self.chain.append(fat32.allocator, next) catch return fs.Error.OutOfMemory;
        }

        return .{
            .cluster = self.chain.items[index],
            .file_offset = index * bytes_per_cluster,
        };
    }
};

/// Release filesystem-specific resources associated with the file context.
fn fclose(ctx: *anyopaque, allocator: Allocator) void {
    const file: *FileImpl = @ptrCast(@alignCast(ctx));

    file.fat32.lock.lock();
    file.fat32.flushCache();
    file.fat32.lock.unlock();
    file.chain.deinit(file.fat32.allocator);

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
        .symlink, .socket => unreachable,
    };
}

/// Get the next file entry in a directory file.
fn fiterate(iter: *fs.File.Iterator, allocator: Allocator) fs.Error!?fs.File.IterResult {
    const file = iter.file;
    const ctx = FileImpl.from(file);
    const inode = InodeImpl.from(file.path.dentry.getInode());
    const fat32 = inode.fat32;

    fat32.lock.lock();
    defer fat32.lock.unlock();

    var diter = DirIterator{
        .fat32 = fat32,
        .cluster = inode.cluster,
    };

    // Resume from the cached cursor.
    if (ctx.dcursor) |c| {
        if (c.consumed == iter.offset) {
            diter.cluster = c.cluster;
            diter.offset = c.offset;
            diter.consumed = c.consumed;
        }
    }
    if (diter.consumed != iter.offset) {
        diter.seek(iter.offset, allocator) catch return null;
    }

    if (try diter.next(allocator)) |result| {
        defer result.deinit(allocator);

        iter.offset = diter.consumed;
        ctx.dcursor = .{
            .consumed = diter.consumed,
            .cluster = diter.cluster,
            .offset = diter.offset,
        };
        return .{
            .name = try allocator.dupe(u8, result.name),
            .inum = result.pos.toInodeNumber(),
            .type = if (result.entry.attr.directory) .directory else .regular,
        };
    } else return null;
}

/// Maximum number of sectors read by a single device request.
const max_read_sectors = 256;
/// Maximum number of sectors written by a single request.
const max_write_sectors = 256;

/// Read data from a regular file.
fn fread(file: *fs.File, buf: []u8, offset: usize) fs.Error!usize {
    const ctx = FileImpl.from(file);

    const file_size = file.path.dentry.getInode().size;
    if (offset >= file_size) return 0;

    const fat32 = ctx.fat32;
    const bytes_per_cluster = @as(u64, fat32.bpb.sec_per_clus) * sector_size;

    fat32.lock.lock();
    defer fat32.lock.unlock();

    // Seek to the cluster that contains `offset`.
    const clsoff = try ctx.seekCluster(offset);
    const clus = clsoff.cluster;
    const clus_file_offset = clsoff.file_offset;

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

        const num_whole_sec = (read_buf.len - bytes_read) / sector_size;
        const sec_in_clus_remain = fat32.bpb.sec_per_clus - sector_in_clus;
        var nsectors = @min(num_whole_sec, sec_in_clus_remain);
        var extra_clus: u32 = 0;
        const to_copy = if (offset_in_sec == 0 and nsectors > 0) blk: {
            // Merge physically contiguous clusters into a single request.
            if (nsectors == sec_in_clus_remain) {
                while (nsectors < @min(num_whole_sec, max_read_sectors)) {
                    const next = try fat32.getNextCluster(cur_clus + extra_clus) orelse break;
                    if (next != cur_clus + extra_clus + 1) break; // not physically contiguous
                    extra_clus += 1;
                    nsectors += @min(num_whole_sec - nsectors, fat32.bpb.sec_per_clus);
                }
            }

            // Fast path: read whole sectors directly from the device.
            const chunk_len = nsectors * sector_size;

            // Write-back dirty sectors before multiple sector reads.
            try fat32.cache.flushRange(fat32, lba, nsectors);
            // Read directly from the device since cached I/O is limited to single-sector accesses.
            try fat32.device.readBlocks(lba, read_buf[bytes_read..][0..chunk_len]);
            break :blk chunk_len;
        } else blk: {
            // Slow path: read partial sectors through the cache.

            // Read through cache since this is always single-sector read.
            var sec_buf: [sector_size]u8 = undefined;
            try fat32.cache.read(fat32, lba, &sec_buf);

            const n = @min(sector_size - offset_in_sec, read_buf.len - bytes_read);
            uaccess.copy(read_buf[bytes_read..], sec_buf[offset_in_sec..], n) catch {
                return error.IoError;
            };
            break :blk n;
        };

        bytes_read += to_copy;
        cur_offset += to_copy;
        cur_clus += extra_clus;
        cur_clus_file_offset += @as(u64, extra_clus) * bytes_per_cluster;

        // If we crossed a cluster boundary, follow the FAT chain to seek the next cluster.
        if (cur_offset - cur_clus_file_offset >= bytes_per_cluster) {
            rtt.expect(cur_offset == cur_clus_file_offset + bytes_per_cluster);
            cur_clus = try fat32.getNextCluster(cur_clus) orelse break;
            cur_clus_file_offset += bytes_per_cluster;
        }
    }

    // Update cache to the last cluster read.
    ctx.cache = .{
        .cluster = cur_clus,
        .file_offset = cur_clus_file_offset,
    };

    return bytes_read;
}

/// Zeroes used to zero-fills sectors.
///
/// The size must be smaller than a cluster size.
const zero_chunk: [32 * sector_size]u8 = @splat(0);

/// Write data to a regular file.
///
/// Extend the file size if necessary.
/// If `offset` is beyond the current EOF, the gap is zero-filled.
fn fwrite(file: *fs.File, buf: []const u8, offset: usize) fs.Error!usize {
    const ctx = FileImpl.from(file);
    const fat32 = ctx.fat32;
    const inode = file.path.dentry.getInode();
    const bytes_per_cluster = @as(u64, fat32.bpb.sec_per_clus) * sector_size;

    // Nothing to write and nothing to zero-fill.
    if (buf.len == 0 and offset <= inode.size) return 0;

    // Check upper limit for the new file size.
    const new_size = std.math.add(usize, offset, buf.len) catch {
        return fs.Error.InvalidArgument;
    };
    if (new_size > std.math.maxInt(u32)) {
        return fs.Error.InvalidArgument;
    }

    fat32.lock.lock();
    defer fat32.lock.unlock();

    const old_size = inode.size;
    const dst_start = @min(offset, old_size);
    const zero_len = offset - dst_start;
    const total_len = zero_len + buf.len;

    // Seek to the cluster that contains `dst_start`.
    const clsoff = if (dst_start != 0 and dst_start % bytes_per_cluster == 0) blk: {
        // Cluster boundary. Reuse the cached cluster if it already starts at `dst_start`.
        if (ctx.cache) |c| if (c.file_offset == dst_start) break :blk c;

        // Get next cluster or allocate a new one.
        const prev = try ctx.seekCluster(dst_start - 1);
        const next =
            try fat32.getNextCluster(prev.cluster) orelse
            try fat32.allocateCluster(prev.cluster);
        break :blk ClsOff{
            .cluster = next,
            .file_offset = prev.file_offset + bytes_per_cluster,
        };
    } else try ctx.seekCluster(dst_start);

    const clus = clsoff.cluster;
    const clus_file_offset = clsoff.file_offset;

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

        const num_whole_sec = (total_len - written) / sector_size;
        const sec_in_clus_remain = fat32.bpb.sec_per_clus - sector_in_clus;
        var nsectors = @min(num_whole_sec, sec_in_clus_remain);
        var extra_clus: u32 = 0;
        const num_zero_sec = if (written < zero_len)
            (zero_len - written) / sector_size
        else
            0;

        const to_write = if (offset_in_sec == 0 and num_zero_sec > 0) blk: {
            // Zero-fill fast path: batch write zero-sectors
            const chunk_len = @as(usize, @min(
                num_zero_sec,
                sec_in_clus_remain,
                zero_chunk.len / sector_size,
            )) * sector_size;
            fat32.cache.discard(lba, chunk_len / sector_size);
            try fat32.device.writeBlocks(lba, zero_chunk[0..chunk_len]);
            break :blk chunk_len;
        } else if (offset_in_sec == 0 and written >= zero_len and nsectors > 0) blk: {
            // Merge physically contiguous clusters into a single request.
            if (nsectors == sec_in_clus_remain) {
                while (nsectors < @min(num_whole_sec, max_write_sectors)) {
                    const last = cur_clus + extra_clus;
                    const next =
                        try fat32.getNextCluster(last) orelse
                        try fat32.allocateCluster(last);
                    if (next != last + 1) break; // not physically contiguous
                    extra_clus += 1;
                    nsectors += @min(num_whole_sec - nsectors, fat32.bpb.sec_per_clus);
                }
            }

            // Fast path: batch write whole sectors from the buffer
            const chunk_len = nsectors * sector_size;
            const data_off = written - zero_len;
            fat32.cache.discard(lba, nsectors);
            try fat32.device.writeBlocks(lba, buf[data_off..][0..chunk_len]);
            break :blk chunk_len;
        } else blk: {
            // Slow-path: read-modify-write for partial sectors
            const n = @min(sector_size - offset_in_sec, total_len - written);

            // Read-modify-write unless we're overwriting the whole sector.
            var sec_buf: [sector_size]u8 = undefined;
            if (offset_in_sec != 0 or n < sector_size) {
                try fat32.cache.read(fat32, lba, &sec_buf);
            }

            if (written < zero_len) {
                const zero_copy = @min(n, zero_len - written);
                @memset(sec_buf[offset_in_sec..][0..zero_copy], 0);
                if (zero_copy < n) {
                    uaccess.copy(sec_buf[offset_in_sec + zero_copy ..], buf, n - zero_copy) catch {
                        return error.IoError;
                    };
                }
            } else {
                const data_off = written - zero_len;
                uaccess.copy(sec_buf[offset_in_sec..], buf[data_off..], n) catch {
                    return error.IoError;
                };
            }

            try fat32.cache.write(fat32, lba, &sec_buf);
            break :blk n;
        };

        written += to_write;
        cur_offset += to_write;
        cur_clus += extra_clus;
        cur_clus_file_offset += @as(u64, extra_clus) * bytes_per_cluster;

        // If we crossed a cluster boundary, follow or extend the FAT chain.
        if (cur_offset - cur_clus_file_offset >= bytes_per_cluster) {
            rtt.expect(cur_offset == cur_clus_file_offset + bytes_per_cluster);
            cur_clus = try fat32.getNextCluster(cur_clus) orelse try fat32.allocateCluster(cur_clus);
            cur_clus_file_offset += bytes_per_cluster;
        }
    }

    // Update cache to the last cluster written.
    ctx.cache = .{
        .cluster = cur_clus,
        .file_offset = cur_clus_file_offset,
    };

    // Update the directory entry.
    const grow = new_size > old_size;
    if (grow) inode.size = new_size;
    if (fat32.hasDirEntry(inode)) try fat32.updateDirEntry(
        inode.number,
        if (grow) new_size else null,
        inode.times,
    );

    return buf.len;
}

/// Change the size of a regular file.
///
/// Growing the file zero-fills the new region.
/// Shrinking the file frees the cluster chain beyond the new size,
/// but always keeps at least the file's first cluster.
fn ftruncate(file: *fs.File, new_size: usize) fs.Error!void {
    const ctx = FileImpl.from(file);
    const fat32 = ctx.fat32;
    const inode = file.path.dentry.getInode();

    // No size change.
    if (new_size == inode.size) {
        return;
    }

    // Extending the size.
    if (new_size > inode.size) {
        _ = try fwrite(file, &[_]u8{}, new_size);
        return;
    }

    fat32.lock.lock();
    defer fat32.lock.unlock();
    defer fat32.flushCache();

    // Walk to the cluster that will remain the new last cluster of the chain.
    const last_kept_offset = if (new_size == 0) 0 else new_size - 1;
    const clsoff = try ctx.seekCluster(last_kept_offset);
    const clus = clsoff.cluster;
    const clus_file_offset = clsoff.file_offset;

    // Free the rest of the chain and terminate it at the kept cluster.
    if (try fat32.getNextCluster(clus)) |next| {
        fat32.chain_gen +%= 1;
        try fat32.freeCluster(next);
        try fat32.setFatEntry(clus, fat_eoc_min);
    }

    // Update the cache.
    ctx.cache = .{ .cluster = clus, .file_offset = clus_file_offset };

    inode.size = new_size;
    if (fat32.hasDirEntry(inode)) {
        try fat32.updateDirEntry(inode.number, new_size, inode.times);
    }
}

/// Whether the inode still has a corresponding on-disk directory entry.
///
/// False for the root directory (which has no on-disk entry)
/// and for inodes whose entry has already been marked deleted by unlink or rmdir.
fn hasDirEntry(self: *Self, inode: *fs.Inode) bool {
    if (inode == &self.root.common) return false;
    return !InodeImpl.from(inode).unlinked;
}

/// Update mutable fields of the on-disk directory entry.
///
/// Fields specified as null do not change.
///
/// Caller must hold `self.lock`.
fn updateDirEntry(self: *Self, inum: fs.Inode.Number, size: ?usize, times: ?fs.Times) fs.Error!void {
    const pos = Position.fromInodeNumber(inum);

    var buf: [sector_size]u8 = undefined;
    try self.readBlocks(pos.sector, &buf);

    const ent: *DirEntry = @ptrCast(@alignCast(&buf[pos.offset]));
    if (size) |sz| ent.file_size = @intCast(sz);
    if (times) |t| writeTimeFields(ent, t);

    try self.writeBlocks(pos.sector, &buf);
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

/// Convert LBA to cluster number.
fn lbaToCluster(self: *const Self, lba: Lba) Cluster {
    const first_data_cluster = 2;
    const first_data_sector = self.bpb.rsvd_sec_cnt +
        (self.bpb.num_fats * self.bpb.fat_sz32);

    return @intCast((lba - first_data_sector) / self.bpb.sec_per_clus + first_data_cluster);
}

/// Advance a directory position by one entry.
///
/// Crosses sector and cluster boundaries as necessary.
fn advanceDirPos(self: *Self, pos: Position) fs.Error!Position {
    const new_offset = pos.offset + @sizeOf(DirEntry);
    if (new_offset < sector_size) return .{
        .sector = pos.sector,
        .offset = new_offset,
    };

    const cluster = self.lbaToCluster(pos.sector);
    const sector_in_clus = pos.sector - self.clusterToLba(cluster);
    if (sector_in_clus + 1 < self.bpb.sec_per_clus) return .{
        .sector = pos.sector + 1,
        .offset = 0,
    };

    const next = try self.getNextCluster(cluster) orelse return fs.Error.CorruptedData;
    return .{
        .sector = self.clusterToLba(next),
        .offset = 0,
    };
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
    try self.readBlocks(fat_sector, &buf);

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
            try self.readBlocks(lba, &buf);

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
            try self.writeBlocks(lba + sec, &buf);
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
    var clus = if (root_clus <= self.free_clus_hint and self.free_clus_hint < total_fat_entries)
        self.free_clus_hint
    else
        root_clus;

    var visited: u64 = 0;
    while (visited < total_fat_entries - root_clus) : (visited += 1) {
        const fat_offset = clus * fat_entry_size;
        const fat_sector = @as(u64, self.bpb.rsvd_sec_cnt) + fat_offset / sector_size;
        const entry_offset = fat_offset % sector_size;

        if (fat_sector != current_fat_sector) {
            try self.readBlocks(fat_sector, &buf);
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

            // Update free cluster hint.
            self.free_clus_hint = clus + 1;

            return clus;
        }

        clus += 1;
        if (clus >= total_fat_entries) clus = root_clus;
    }

    return fs.Error.NoSpace;
}

/// Free the cluster chain starting from the given cluster.
fn freeCluster(self: *Self, clus: Cluster) fs.Error!void {
    if (clus < self.free_clus_hint) {
        self.free_clus_hint = clus;
    }

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
    try self.readBlocks(first_fat_sec, &buf);

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
        try self.writeBlocks(fat_sector, &buf);
    }
}

/// Convert a cluster data to a directory entry slice.
fn clus2dirents(buf: []const u8) []const DirEntry {
    rtt.expectEqual(0, buf.len % @sizeOf(DirEntry));
    const ptr: [*]const DirEntry = @ptrCast(@alignCast(buf.ptr));
    return ptr[0 .. buf.len / @sizeOf(DirEntry)];
}

/// Write the given timestamps into the timestamp fields of a directory entry.
fn writeTimeFields(dirent: *DirEntry, times: fs.Times) void {
    const crt = ftime.encode(times.ctime);
    dirent.create_time_tenth = crt.tenth;
    dirent.create_time = @bitCast(crt.time);
    dirent.create_date = @bitCast(crt.date);

    const wrt = ftime.encode(times.mtime);
    dirent.write_time = @bitCast(wrt.time);
    dirent.write_date = @bitCast(wrt.date);

    dirent.access_date = @bitCast(ftime.encode(times.atime).date);
}

/// Read the timestamp fields of a directory entry.
fn readTimeFields(dirent: *const DirEntry) fs.Times {
    return .{
        .atime = ftime.decode(
            @bitCast(dirent.access_date),
            .{ .hour = 0, .min = 0, .sec = 0 },
            0,
        ),
        .mtime = ftime.decode(
            @bitCast(dirent.write_date),
            @bitCast(dirent.write_time),
            0,
        ),
        .ctime = ftime.decode(
            @bitCast(dirent.create_date),
            @bitCast(dirent.create_time),
            dirent.create_time_tenth,
        ),
    };
}

/// Conversion between FS timestamp and the packed date fields of a FAT directory entry.
const ftime = struct {
    /// FAT epoch year.
    const epoch_year = 1980;
    /// Seconds between the UNIX epoch (1970) and the FAT epoch (1980).
    const fat_epoch_unix: u64 = 315_532_800;

    const Repr = struct {
        /// Date.
        date: Date,
        /// Time.
        time: Time,
        /// Fine resolution (10ms units).
        tenth: u8,
    };

    const Time = packed struct(u16) {
        /// Seconds divided by 2.
        sec: u5,
        /// Minutes.
        min: u6,
        /// Hours.
        hour: u5,
    };

    const Date = packed struct(u16) {
        /// Day of the month. 1-origin.
        day: u5,
        /// Month. 1-origin.
        month: u4,
        /// Years since FAT epoch.
        year: u7,
    };

    pub fn encode(ts: fs.Timestamp) Repr {
        const total_secs = ts.ns / std.time.ns_per_s;
        if (total_secs < fat_epoch_unix) {
            return .{
                .date = .{ .year = 0, .month = 1, .day = 1 },
                .time = .{ .hour = 0, .min = 0, .sec = 0 },
                .tenth = 0,
            };
        }

        const es = std.time.epoch.EpochSeconds{ .secs = total_secs };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        const second = ds.getSecondsIntoMinute();
        const sub_ns = ts.ns % std.time.ns_per_s;

        return .{
            .date = .{
                .year = @intCast(yd.year - epoch_year),
                .month = md.month.numeric(),
                .day = @intCast(md.day_index + 1),
            },
            .time = .{
                .hour = ds.getHoursIntoDay(),
                .min = ds.getMinutesIntoHour(),
                .sec = @intCast(second / 2),
            },
            .tenth = @intCast(@as(u32, second % 2) * 100 + sub_ns / (10 * std.time.ns_per_ms)),
        };
    }

    pub fn decode(date: Date, time: Time, tenth: u8) fs.Timestamp {
        if (@as(u16, @bitCast(date)) == 0) return .zero;
        if (date.month < 1 or date.month > 12 or date.day < 1) return .zero;

        const days = daysFromCivil(
            epoch_year + @as(i64, date.year),
            date.month,
            date.day,
        );
        const second: u64 = @as(u64, time.sec) * 2 + tenth / 100;
        const sub_ns: u64 = @as(u64, tenth % 100) * 10 * std.time.ns_per_ms;

        const total_secs = @as(u64, @intCast(days)) * std.time.s_per_day +
            @as(u64, time.hour) * std.time.s_per_hour +
            @as(u64, time.min) * std.time.s_per_min + second;
        return .{ .ns = total_secs * std.time.ns_per_s + sub_ns };
    }

    /// Days from the UNIX epoch to proleptic Gregorian.
    ///
    /// Using Howard Hinnant's algorithm.
    fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
        const y = if (month <= 2) year - 1 else year;
        const era = @divFloor(y, 400);
        const yoe = y - era * 400;
        const mp = @mod(month + 9, 12);
        const doy = @divFloor(153 * mp + 2, 5) + day - 1;
        const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
        return era * 146097 + doe - 719468;
    }
};

/// Build the 11-byte SFN field for a name that already fits the 8.3 format.
fn sfnArray(name: []const u8) [DirEntry.sfn_len]u8 {
    rtt.expect(isFitSfn(name));

    const stem = sfnGetStem(name);
    const ext = sfnGetExt(name);
    var sfn: [DirEntry.sfn_len]u8 = @splat(' ');
    @memcpy(sfn[0..stem.len], stem);
    @memcpy(sfn[8..][0..ext.len], ext);

    return sfn;
}

/// Compute checksum of the short name.
fn computeSfnChecksum(name: *const [DirEntry.sfn_len]u8) u8 {
    var sum: u8 = 0;
    for (name) |c| {
        sum = ((sum >> 1) | ((sum & 1) << 7)) +% c;
    }
    return sum;
}

/// Generate a unique 8.3 short name for a long file name.
///
/// Uses numeric tail generation algorithm to avoid name collision.
fn genShortName(self: *Self, dir_cluster: Cluster, name: []const u8) fs.Error![DirEntry.sfn_len]u8 {
    const stem = sfnGetStem(name);
    const ext = sfnGetExt(name);

    var stem_buf: [8]u8 = undefined;
    var stem_len: usize = 0;
    for (stem) |c| {
        if (stem_len >= stem_buf.len) break;
        if (std.ascii.isAlphanumeric(c)) {
            stem_buf[stem_len] = std.ascii.toUpper(c);
            stem_len += 1;
        }
    }
    if (stem_len == 0) {
        stem_buf[0] = '_';
        stem_len = 1;
    }

    var ext_buf: [3]u8 = undefined;
    var ext_len: usize = 0;
    for (ext) |c| {
        if (ext_len >= ext_buf.len) break;
        if (std.ascii.isAlphanumeric(c)) {
            ext_buf[ext_len] = std.ascii.toUpper(c);
            ext_len += 1;
        }
    }

    const retry_max = 999_999;
    var tail: u32 = 1;
    while (tail <= retry_max) : (tail += 1) {
        var tail_buf: [7]u8 = undefined; // "~" + up to 6 digits
        const tail_str = std.fmt.bufPrint(&tail_buf, "~{d}", .{tail}) catch unreachable;
        const base_len = @min(stem_len, stem_buf.len - tail_str.len);

        var candidate: [DirEntry.sfn_len]u8 = @splat(' ');
        @memcpy(candidate[0..base_len], stem_buf[0..base_len]);
        @memcpy(candidate[base_len..][0..tail_str.len], tail_str);
        @memcpy(candidate[8..][0..ext_len], ext_buf[0..ext_len]);

        if (!try self.sfnExists(dir_cluster, &candidate)) {
            return candidate;
        }
    } else return fs.Error.NoSpace;
}

/// Check if a directory entry with the exact given short name already exists.
///
/// The search continues until the end of the directory cluster chain or matching entry is found.
fn sfnExists(self: *Self, start: Cluster, sfn: *const [DirEntry.sfn_len]u8) fs.Error!bool {
    var clus = start;
    var buf: [sector_size]u8 = undefined;

    while (true) {
        const clus_lba = self.clusterToLba(clus);
        for (0..self.bpb.sec_per_clus) |sec| {
            try self.readBlocks(clus_lba + sec, &buf);

            for (clus2dirents(&buf)) |ent| {
                if (ent.isFree()) return false;
                if (ent.isDeleted() or ent.isLongName() or ent.attr.volume_id) continue;
                if (std.mem.eql(u8, &ent.name, sfn)) return true;
            }
        }

        clus = try self.getNextCluster(clus) orelse return false;
    }
}

/// Build the LFN entries representing the given UTF-16 long name.
///
/// Ordered from the last entry to the first.
fn buildLfnEntries(buf: []LongNameEntry, name: []const u16, sfn_checksum: u8) []const LongNameEntry {
    const chars_per_entry = LongNameEntry.chars_per_entry;
    const n = lfnEntryCount(name.len);
    for (0..n) |i| {
        const ord: u8 = @intCast(n - i);
        const seg_start = (ord - 1) * chars_per_entry;
        const seg = name[seg_start..@min(seg_start + chars_per_entry, name.len)];

        var chars: [LongNameEntry.chars_per_entry]u16 = @splat(0xFFFF);
        @memcpy(chars[0..seg.len], seg);
        if (seg.len < chars.len) chars[seg.len] = 0x0000;

        buf[i] = std.mem.zeroInit(LongNameEntry, .{
            .order = ord | (if (i == 0) @as(u8, LongNameEntry.last_entry_flag) else 0),
            .attr = DirEntry.Attributes.long_name,
            .chksum = sfn_checksum,
        });
        @memcpy(&buf[i].name1, chars[0..5]);
        @memcpy(&buf[i].name2, chars[5..11]);
        @memcpy(&buf[i].name3, chars[11..13]);
    }

    return buf[0..n];
}

/// Number of LFN entries needed to represent a name of `len` UTF-16 code units.
fn lfnEntryCount(len: usize) usize {
    return (len + LongNameEntry.chars_per_entry - 1) / LongNameEntry.chars_per_entry;
}

/// Write the given directory entries starting at the given position.
///
/// Caller must ensure that entries in the given position are reserved for this use.
///
/// Returns the position of the last entry written.
fn writeDirEntries(self: *Self, start: Position, entries: []const [@sizeOf(DirEntry)]u8) fs.Error!Position {
    var pos = start;
    var buf: [sector_size]u8 = undefined;

    for (entries, 0..) |raw, i| {
        try self.readBlocks(pos.sector, &buf);
        @memcpy(buf[pos.offset..][0..raw.len], &raw);
        try self.writeBlocks(pos.sector, &buf);

        if (i + 1 < entries.len) pos = try self.advanceDirPos(pos);
    }

    return pos;
}

/// Mark the LFN entries that precede the given directory entry at `target` as deleted.
///
/// This function does not touch the SFN entry.
fn deletePrecedingLfnEntries(
    self: *Self,
    /// Cluster number of the directory containing the target entry.
    dir_clus: Cluster,
    /// Position of the SFN directory entry that follows the LFN entries to be deleted.
    target: Position,
    /// SFN matched against the checksum of the LFN entries.
    sfn: *const [DirEntry.sfn_len]u8,
) fs.Error!void {
    const target_checksum = computeSfnChecksum(sfn);

    var clus = dir_clus;
    var buf: [sector_size]u8 = undefined;

    var positions: [LongNameEntry.max_entries]Position = undefined;
    var count: usize = 0;
    var next_ord: u8 = 0;
    var checksum: u8 = 0;

    while (true) {
        // Iterate over sectors in one cluster.
        const clus_lba = self.clusterToLba(clus);
        for (0..self.bpb.sec_per_clus) |sec| {
            const lba = clus_lba + sec;
            try self.readBlocks(lba, &buf);

            // Iterate over directory entries in the sector.
            for (clus2dirents(&buf), 0..) |ent, i| {
                const pos = Position{
                    .sector = lba,
                    .offset = i * @sizeOf(DirEntry),
                };

                // Reached the target SFN entry.
                if (pos.sector == target.sector and pos.offset == target.offset) {
                    if (count > 0 and next_ord == 0 and checksum == target_checksum) {
                        for (positions[0..count]) |p| {
                            try self.markPositionDeleted(p);
                        }
                    }
                    return;
                }

                // Reached end of directory entries.
                if (ent.isFree()) {
                    return;
                }

                // Skip deleted entries.
                if (ent.isDeleted()) {
                    count = 0;
                    next_ord = 0;
                    continue;
                }

                // Found a long name entry.
                if (ent.isLongName()) {
                    const lfn: *const LongNameEntry = @ptrCast(&ent);
                    const ord = lfn.getOrder();
                    if (lfn.isLast()) {
                        next_ord = ord;
                        checksum = lfn.chksum;
                        count = 0;
                    }
                    if (ord == next_ord and lfn.chksum == checksum) {
                        positions[ord - 1] = pos;
                        count += 1;
                        next_ord = ord - 1;
                    } else {
                        count = 0;
                        next_ord = 0;
                    }
                    continue;
                }

                count = 0;
                next_ord = 0;
            }
        }

        clus = try self.getNextCluster(clus) orelse return;
    }
}

/// Mark the directory entry at `pos` as deleted.
fn markPositionDeleted(self: *Self, pos: Position) fs.Error!void {
    var buf: [sector_size]u8 = undefined;
    try self.readBlocks(pos.sector, &buf);
    const ent: *DirEntry = @ptrCast(@alignCast(&buf[pos.offset]));
    ent.markDeleted();
    try self.writeBlocks(pos.sector, &buf);
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
// Sector cache
// =============================================================

/// Read blocks from the device into the given buffer.
///
/// When the requested size equals the sector size, cached I/O is used.
fn readBlocks(self: *Self, lba: Lba, buf: []u8) fs.Error!void {
    rtt.expectEqual(0, buf.len % sector_size);

    if (buf.len == sector_size) {
        // Cached read for a single sector.
        return self.cache.read(self, lba, buf);
    } else {
        // Direct read for multiple sectors.
        try self.cache.flushRange(self, lba, buf.len / sector_size);
        return self.device.readBlocks(lba, buf);
    }
}

/// Write blocks to the device from the given buffer.
///
/// When the provided data length equals the sector size, cached I/O is used.
fn writeBlocks(self: *Self, lba: Lba, data: []const u8) fs.Error!void {
    rtt.expectEqual(0, data.len % sector_size);

    if (data.len == sector_size) {
        // Cached write for a single sector.
        return self.cache.write(self, lba, data);
    } else {
        // Direct write for multiple sectors.
        self.cache.discard(lba, data.len / sector_size);
        return self.device.writeBlocks(lba, data);
    }
}

/// Write back cached sectors to the device.
///
/// Do nothing when the number of dirty sectors do not reach the threshold.
///
/// Failed sectors are kept dirty.
fn flushCache(self: *Self) void {
    if (self.cache.ndirty < SectorCache.flush_threshold) {
        return;
    }

    self.cache.flushAll(self) catch {};
}

/// Write-back cache for FAT sectors.
const SectorCache = struct {
    /// Number of ways in a set.
    const nways = 4; // TODO: find most optimal number
    /// Number of sets.
    const nsets = 1024;
    /// Number of cache slots.
    ///
    /// One slot caches a single sector.
    const nslots = nsets * nways;
    /// Number of dirty slots until write-back.
    const flush_threshold = nslots / 4;

    comptime {
        urd.comptimeAssert(std.math.isPowerOfTwo(nsets), "Invalid nsets: {d}", .{nsets});
    }

    /// Cache entry slot type.
    const Slot = struct {
        /// Cached sector LBA.
        lba: ?Lba = null,
        /// Whether the buffered sector is dirty.
        dirty: bool = false,
        /// Timestamp at the last access.
        stamp: u64 = 0,
    };

    /// Per-slot metadata.
    slots: []Slot = &.{},
    /// Sector data for all cached entries.
    data: []u8 = &.{},
    /// Monotonic access counter.
    clock: u64 = 0,
    /// Number of dirty slots.
    ndirty: usize = 0,

    /// Read one sector at the given LBA into the given buffer.
    ///
    /// If the sector is cached, just returns the cached data.
    /// If the sector is not cached, the sector is read from the device into the cache.
    pub fn read(self: *SectorCache, fat32: *Self, lba: Lba, buf: []u8) fs.Error!void {
        const index = self.find(lba) orelse blk: {
            const slot = try self.reserve(fat32, lba);
            fat32.device.readBlocks(lba, self.sector(slot)) catch |e| {
                self.slots[slot].lba = null;
                return e;
            };
            break :blk slot;
        };
        @memcpy(buf, self.sector(index));
        self.touch(index);
    }

    /// Write one sector at the given LBA from the given buffer.
    ///
    /// If the sector is cached, it updates the cached data and marks it as dirty.
    pub fn write(self: *SectorCache, fat32: *Self, lba: Lba, data: []const u8) fs.Error!void {
        const i = self.find(lba) orelse try self.reserve(fat32, lba);
        @memcpy(self.sector(i), data);
        if (!self.slots[i].dirty) self.ndirty += 1;
        self.slots[i].dirty = true;
        self.touch(i);
    }

    /// Discard cached sectors in the given range without writing them back.
    ///
    /// Can be used when the range is about to be overwritten bypassing the cache.
    pub fn discard(self: *SectorCache, lba: Lba, count: usize) void {
        for (0..count) |i| {
            const index = self.find(lba + i) orelse continue;
            if (self.slots[index].dirty) {
                self.slots[index].dirty = false;
                self.ndirty -= 1;
            }
            self.slots[index].lba = null;
        }
    }

    /// Flush dirty cache slots in the given range to the device.
    ///
    /// Failed sectors are kept dirty.
    pub fn flushRange(self: *SectorCache, fat32: *Self, lba: Lba, count: usize) fs.Error!void {
        if (self.ndirty == 0) return;

        for (0..count) |i| {
            const index = self.find(lba + i) orelse continue;
            if (!self.slots[index].dirty) continue;
            try fat32.device.writeBlocks(lba + i, self.sector(index));
            self.slots[index].dirty = false;
            self.ndirty -= 1;
        }
    }

    /// Flush all dirty cache slots to the device.
    ///
    /// Failed sectors are kept dirty.
    pub fn flushAll(self: *SectorCache, fat32: *Self) fs.Error!void {
        if (self.ndirty == 0) return;

        var failed = false;
        for (self.slots, 0..) |*s, i| {
            if (!s.dirty) {
                continue;
            }
            fat32.device.writeBlocks(
                s.lba.?,
                self.sector(i),
            ) catch |e| {
                log.err("failed to flush dirty cache: {t}", .{e});
                failed = true;
                continue; // keep it dirty
            };
            s.dirty = false;
            self.ndirty -= 1;
        }

        if (failed) return fs.Error.IoError;
    }

    /// Reserve a cache slot for the given LBA,
    ///
    /// When cache slots are full, the least-recently-used slot is evicted to the device.
    /// Returns the index of the reserved cache slot.
    fn reserve(self: *SectorCache, fat32: *Self, lba: Lba) fs.Error!usize {
        const base = getBaseOfSet(lba);
        var victim: usize = base;
        var oldest: u64 = std.math.maxInt(u64);
        for (self.slots[base .. base + nways], base..) |*s, i| {
            if (s.lba) |_| {
                if (s.stamp < oldest) {
                    oldest = s.stamp;
                    victim = i;
                }
            } else {
                victim = i;
                break;
            }
        }

        const slot = &self.slots[victim];
        if (slot.dirty) {
            try fat32.device.writeBlocks(
                slot.lba.?,
                self.sector(victim),
            );
            slot.dirty = false;
            self.ndirty -= 1;
        }
        slot.lba = lba;
        return victim;
    }

    /// Get a reference to the sector cache.
    fn sector(self: *SectorCache, index: usize) []u8 {
        return self.data[index * sector_size ..][0..sector_size];
    }

    /// Find a cache slot containing the sector with the given LBA.
    fn find(self: *SectorCache, lba: Lba) ?usize {
        const base = getBaseOfSet(lba);
        for (self.slots[base .. base + nways], base..) |*s, i| {
            if (s.lba == lba) return i;
        } else return null;
    }

    /// Get the index of the first slot in the set that the given LBA maps to.
    fn getBaseOfSet(lba: Lba) usize {
        // Number of bits to index a set.
        const set_bits = std.math.log2(nsets);
        // Multiplier of the Fibonacci hashing.
        const hash_multiplier = 0x9E3779B97F4A7C15;

        const set = (lba *% hash_multiplier) >> (64 - set_bits);
        return set * nways;
    }

    /// Update the access timestamp for the given cache slot.
    fn touch(self: *SectorCache, index: usize) void {
        self.clock +%= 1;
        self.slots[index].stamp = self.clock;
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
        const size = @sizeOf(Bpb);
        const expected = 90;
        urd.comptimeAssert(size == expected, "Invalid size of BPB: expected {d} bytes, found {d} bytes", .{ expected, size });
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

    /// Extract UTF-16 code units from this entry to the buffer.
    ///
    /// Returns the number of code units written.
    fn extractChars(self: *const LongNameEntry, buf: []u16) usize {
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
                    buf[pos] = c;
                    pos += 1;
                }
            }
        }

        return pos;
    }

    comptime {
        urd.comptimeAssert(32 == @sizeOf(LongNameEntry), "Invalid size of LongNameEntry", .{});
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
    create_time: u16 align(1),
    /// Creation date.
    create_date: u16 align(1),
    /// Last access date.
    access_date: u16 align(1),
    /// High word of first cluster.
    first_cluster_high: u16 align(1),
    /// Last modification time.
    write_time: u16 align(1),
    /// Last modification date.
    write_date: u16 align(1),
    /// Low word of first cluster.
    first_cluster_low: u16 align(1),
    /// File size in bytes.
    file_size: u32 align(1),

    comptime {
        urd.comptimeAssert(32 == @sizeOf(DirEntry), "Invalid size of DirEntry", .{});
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
const Mutex = sync.Mutex;
const uaccess = urd.uaccess;
