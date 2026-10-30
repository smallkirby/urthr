//! Device filesystem.
//!
//! Implements `fs.FileSystem`.

const Self = @This();

/// Owned allocator for this filesystem.
allocator: Allocator,
/// Root inode of this filesystem.
root_inode: *InodeImpl,
/// Inode number assigned to the next inode.
next_inum: usize = 2,
/// Lock protecting the directory entries.
lock: SpinLock = .{},

/// Maximum number of entries in a directory.
const max_entries = 16;

/// Instantiate the device filesystem.
pub fn init(allocator: Allocator) fs.Error!*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .root_inode = undefined,
    };
    self.root_inode = try self.createDirectory(1);

    return self;
}

/// Get the filesystem interface.
pub fn filesystem(self: *Self) fs.FileSystem {
    return .{
        .ptr = self,
        .vtable = &fs_vtable,
        .root = &self.root_inode.common,
    };
}

/// Register a device with the given path and file operations.
///
/// The path is relative to the root of devfs.
/// Directories in the path are created if they don't exist.
pub fn registerDevice(self: *Self, path: []const u8, fops: fs.File.Ops, ctx: ?*anyopaque) fs.Error!void {
    const ie = self.lock.lockDisableIrq();
    defer self.lock.unlockRestoreIrq(ie);

    var dir = self.root_inode;
    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |name| {
        if (name.len == 0) return fs.Error.InvalidArgument;

        if (iter.peek() != null) {
            dir = try self.getOrCreateDirectory(dir, name);
        } else {
            try self.addDevice(dir, name, fops, ctx);
        }
    }
}

/// Entries of a directory.
const Directory = struct {
    /// Entries.
    entries: [max_entries]DevEntry = undefined,
    /// The number of entries.
    count: usize = 0,

    /// Find an entry by name.
    fn find(self: *const Directory, name: []const u8) ?DevEntry {
        for (self.entries[0..self.count]) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        } else return null;
    }
};

/// File entry.
const DevEntry = struct {
    /// Name of the file.
    name: []const u8,
    /// Inode implementation.
    inode: *InodeImpl,
};

/// Allocate a new inode number.
///
/// The lock must be held.
fn allocInum(self: *Self) usize {
    rtt.expect(self.lock.isLocked());

    defer self.next_inum += 1;
    return self.next_inum;
}

/// Create a directory with the given inode number.
///
/// The created directory does not belong to any parent directory.
fn createDirectory(self: *Self, number: usize) fs.Error!*InodeImpl {
    const inode = try self.allocator.create(InodeImpl);
    errdefer self.allocator.destroy(inode);
    const dir = try self.allocator.create(Directory);
    errdefer self.allocator.destroy(dir);

    dir.* = .{};
    inode.* = .{
        .common = .{
            .number = number,
            .size = 0,
            .ftype = .directory,
            .iops = dir_inode_vtable,
            .fops = file_vtable,
        },
        .devfs = self,
        .dir = dir,
    };

    return inode;
}

/// Get a subdirectory of the directory, or create it if it doesn't exist.
///
/// The lock must be held.
fn getOrCreateDirectory(self: *Self, parent: *InodeImpl, name: []const u8) fs.Error!*InodeImpl {
    rtt.expect(self.lock.isLocked());

    if (parent.dir.?.find(name)) |entry| {
        return if (entry.inode.common.ftype == .directory)
            entry.inode
        else
            fs.Error.NotDirectory;
    }

    const inode = try self.createDirectory(self.allocInum());
    errdefer ideinit(&inode.common);
    try self.addEntry(parent, name, inode);

    return inode;
}

/// Create a device file in the directory.
///
/// The lock must be held.
fn addDevice(self: *Self, parent: *InodeImpl, name: []const u8, fops: fs.File.Ops, ctx: ?*anyopaque) fs.Error!void {
    rtt.expect(self.lock.isLocked());

    const inode = try self.allocator.create(InodeImpl);
    errdefer self.allocator.destroy(inode);

    inode.* = .{
        .common = .{
            .number = self.allocInum(),
            .size = 0,
            .ftype = .regular,
            .iops = dev_inode_vtable,
            .fops = fops,
        },
        .devfs = self,
        .ctx = ctx,
    };
    try self.addEntry(parent, name, inode);
}

/// Add an entry to the directory.
///
/// The lock must be held.
fn addEntry(self: *Self, parent: *InodeImpl, name: []const u8, inode: *InodeImpl) fs.Error!void {
    rtt.expect(self.lock.isLocked());

    const dir = parent.dir.?;
    if (dir.find(name) != null) return fs.Error.AlreadyExists;
    if (dir.count == max_entries) return fs.Error.NoSpace;

    dir.entries[dir.count] = .{
        .name = try self.allocator.dupe(u8, name),
        .inode = inode,
    };
    dir.count += 1;
}

/// Get the entry of the directory at the given index.
fn entryAt(self: *Self, parent: *InodeImpl, index: usize) ?DevEntry {
    const ie = self.lock.lockDisableIrq();
    defer self.lock.unlockRestoreIrq(ie);

    const dir = parent.dir.?;
    return if (index < dir.count) dir.entries[index] else null;
}

// =============================================================
// Filesystem vtable
// =============================================================

const fs_vtable = fs.FileSystem.Vtable{};

// =============================================================
// Inode interface
// =============================================================

/// devfs specific inode implementation.
pub const InodeImpl = struct {
    /// Common part of the inode.
    common: fs.Inode,
    /// Pointer back to the devfs instance.
    devfs: *Self,
    /// Device-specific context.
    ctx: ?*anyopaque = null,
    /// Entries of the directory. Null if the inode is not a directory.
    dir: ?*Directory = null,

    pub fn from(inode: *fs.Inode) *InodeImpl {
        return @fieldParentPtr("common", inode);
    }
};

/// inode vtable for directories.
const dir_inode_vtable = fs.Inode.Ops{
    .lookup = &iDirLookup,
    .deinit = &ideinit,
};

/// inode vtable for device files.
const dev_inode_vtable = fs.Inode.Ops{
    .lookup = &iDevLookup,
    .deinit = &ideinit,
};

fn iDirLookup(dir: *fs.Inode, name: []const u8) fs.Error!?*fs.Inode {
    const ctx = InodeImpl.from(dir);
    const self = ctx.devfs;

    const ie = self.lock.lockDisableIrq();
    defer self.lock.unlockRestoreIrq(ie);

    const entry = ctx.dir.?.find(name) orelse return null;
    entry.inode.common.ref();
    return &entry.inode.common;
}

fn iDevLookup(_: *fs.Inode, _: []const u8) fs.Error!?*fs.Inode {
    return null;
}

fn ideinit(inode: *fs.Inode) void {
    const ctx = InodeImpl.from(inode);
    const allocator = ctx.devfs.allocator;

    if (ctx.dir) |dir| allocator.destroy(dir);
    allocator.destroy(ctx);
}

// =============================================================
// Directory file vtable
// =============================================================

const file_vtable = fs.File.Ops{
    .open = fopen,
    .iterate = fiterate,
    .read = fread,
    .close = fclose,
    .poll = fpoll,
};

fn fopen(inode: *fs.Inode, allocator: Allocator) fs.Error!*anyopaque {
    if (inode.ftype == .directory) {
        const file = try allocator.create(FileImpl);
        file.* = .{ .inode = InodeImpl.from(inode) };

        return @ptrCast(file);
    }

    // Device files carry no per-open state.
    return undefined;
}

const FileImpl = struct {
    inode: *InodeImpl,
};

fn fiterate(iter: *fs.File.Iterator, allocator: Allocator) fs.Error!?fs.File.IterResult {
    const ctx: *FileImpl = @ptrCast(@alignCast(iter.file.ctx));
    const entry = ctx.inode.devfs.entryAt(
        ctx.inode,
        iter.offset,
    ) orelse return null;

    iter.offset += 1;
    return .{
        .name = try allocator.dupe(u8, entry.name),
        .inum = entry.inode.common.number,
        .type = entry.inode.common.ftype,
    };
}

fn fread(_: *fs.File, _: []u8, _: usize) fs.Error!usize {
    return fs.Error.NotFile;
}

fn fclose(ctx: *anyopaque, allocator: Allocator) void {
    const file: *FileImpl = @ptrCast(@alignCast(ctx));
    allocator.destroy(file);
}

fn fpoll(_: *fs.File) fs.Error!fs.PollResult {
    return .{ .events = .none };
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const rtt = common.rtt;
const urd = @import("urthr");
const fs = urd.fs;
const SpinLock = urd.sync.SpinLock;
