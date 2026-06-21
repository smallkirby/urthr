//! Process Filesystem.
//!
//! Implements `fs.FileSystem`.

const Self = @This();

/// Owned allocator for this filesystem.
allocator: Allocator,
/// Root inode of this filesystem.
root_inode: *InodeImpl,
/// Registered entries.
entries: [max_entries]?Entry = [_]?Entry{null} ** max_entries,
/// Number of registered entries.
entry_count: usize = 0,

/// Maximum number of entries that can be registered.
const max_entries = 32;

/// A registered virtual file entry.
const Entry = struct {
    /// File name.
    name: []const u8,
    /// Inode of the file.
    inode: *InodeImpl,
};

/// Instantiate the process filesystem.
pub fn init(allocator: Allocator) fs.Error!*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    // Create the root inode.
    const root = try allocator.create(InodeImpl);
    errdefer allocator.destroy(root);
    root.* = .{
        .common = .{
            .number = 1,
            .size = 0,
            .ftype = .directory,
            .iops = root_inode_vtable,
            .fops = dir_file_vtable,
        },
        .procfs = self,
    };
    root.common.ref();

    self.* = .{
        .allocator = allocator,
        .root_inode = root,
    };

    // Create root proc files.
    try self.registerFile("meminfo", readMeminfo);

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

/// Register a virtual file with the given name and read function.
fn registerFile(self: *Self, name: []const u8, read_fn: ReadFn) fs.Error!void {
    rtt.expect(self.entry_count < max_entries);

    const inode = try self.allocator.create(InodeImpl);
    errdefer self.allocator.destroy(inode);
    const name_copy = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(name_copy);

    const inum = self.allocInum();
    inode.* = .{
        .common = .{
            .number = inum,
            .size = 0,
            .ftype = .regular,
            .iops = file_inode_vtable,
            .fops = freg_vtable,
        },
        .procfs = self,
        .read_fn = read_fn,
    };
    inode.common.ref();

    self.entries[self.entry_count] = .{
        .name = name_copy,
        .inode = inode,
    };
    self.entry_count += 1;
}

/// Allocate a new inode number for a virtual file.
fn allocInum(self: *Self) usize {
    rtt.expect(self.entry_count < max_entries);
    return self.entry_count + 2;
}

// =============================================================
// Filesystem vtable
// =============================================================

const fs_vtable = fs.FileSystem.Vtable{};

// =============================================================
// Inode interface
// =============================================================

/// Read function type for virtual file content.
const ReadFn = *const fn (buf: []u8, pos: usize) fs.Error!usize;

const InodeImpl = struct {
    /// Common part of inode.
    common: fs.Inode,
    /// Pointer to procfs instance.
    procfs: *Self,
    /// Read function for regular files.
    read_fn: ?ReadFn = null,

    pub fn from(inode: *fs.Inode) *InodeImpl {
        return @fieldParentPtr("common", inode);
    }
};

const root_inode_vtable = fs.Inode.Ops{
    .lookup = &iRootLookup,
    .deinit = &iDeinit,
};

const file_inode_vtable = fs.Inode.Ops{
    .lookup = &iFileLookup,
    .deinit = &iDeinit,
};

fn iRootLookup(dir: *fs.Inode, name: []const u8) fs.Error!?*fs.Inode {
    const ctx = InodeImpl.from(dir);
    const self = ctx.procfs;

    for (self.entries[0..self.entry_count]) |entry| {
        const e = entry orelse continue;
        if (std.mem.eql(u8, e.name, name)) {
            e.inode.common.ref();
            return &e.inode.common;
        }
    } else return null;
}

fn iFileLookup(_: *fs.Inode, _: []const u8) fs.Error!?*fs.Inode {
    return null;
}

fn iDeinit(inode: *fs.Inode) void {
    const ctx = InodeImpl.from(inode);
    ctx.procfs.allocator.destroy(ctx);
}

// =============================================================
// Directory file vtable
// =============================================================

const dir_file_vtable = File.Ops{
    .open = fDirOpen,
    .iterate = fDirIterate,
    .read = fDirRead,
    .close = fDirClose,
    .poll = fDirPoll,
};

const DirFileImpl = struct {
    inode: *InodeImpl,
};

fn fDirOpen(inode: *fs.Inode, allocator: Allocator) fs.Error!*anyopaque {
    const file = try allocator.create(DirFileImpl);
    file.* = .{ .inode = InodeImpl.from(inode) };
    return @ptrCast(file);
}

fn fDirIterate(iter: *File.Iterator, allocator: Allocator) fs.Error!?File.IterResult {
    const ctx: *DirFileImpl = @ptrCast(@alignCast(iter.file.ctx));
    const self = ctx.inode.procfs;

    if (iter.offset >= self.entry_count) {
        return null;
    }

    const e = self.entries[iter.offset] orelse return null;
    iter.offset += 1;

    return .{
        .name = try allocator.dupe(u8, e.name),
        .inum = e.inode.common.number,
        .type = .regular,
    };
}

fn fDirRead(_: *File, _: []u8, _: usize) fs.Error!usize {
    return fs.Error.NotFile;
}

fn fDirClose(ctx: *anyopaque, allocator: Allocator) void {
    const file: *DirFileImpl = @ptrCast(@alignCast(ctx));
    allocator.destroy(file);
}

fn fDirPoll(_: *File) fs.Error!fs.PollResult {
    return .{ .events = .none };
}

// =============================================================
// Regular file vtable
// =============================================================

const freg_vtable = File.Ops{
    .open = fregOpen,
    .iterate = fregIterate,
    .read = fregRead,
    .close = fregClose,
    .poll = fregPoll,
};

fn fregOpen(_: *fs.Inode, _: Allocator) fs.Error!*anyopaque {
    return undefined;
}

fn fregIterate(_: *File.Iterator, _: Allocator) fs.Error!?File.IterResult {
    return fs.Error.NotDirectory;
}

fn fregRead(file: *File, buf: []u8, pos: usize) fs.Error!usize {
    const inode = InodeImpl.from(file.path.dentry.inode);
    const read_fn = inode.read_fn orelse return 0;
    return read_fn(buf, pos);
}

fn fregClose(_: *anyopaque, _: Allocator) void {}

fn fregPoll(_: *File) fs.Error!fs.PollResult {
    return .{ .events = .{ .in = true } };
}

// =============================================================
// /proc/meminfo
// =============================================================

fn readMeminfo(buf: []u8, pos: usize) fs.Error!usize {
    const stats = urd.mem.getStats();

    var tmp: [128]u8 = undefined;
    const content = std.fmt.bufPrint(
        &tmp,
        \\MemTotal:     {d: >10} kB
        \\MemFree:      {d: >10} kB
        \\
    ,
        .{
            stats.total_bytes / units.kib,
            stats.free_bytes / units.kib,
        },
    ) catch return 0;

    if (pos >= content.len) return 0;
    const src = content[pos..];
    const n = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);

    return n;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const units = common.units;
const rtt = common.rtt;
const urd = @import("urthr");
const fs = urd.fs;
const File = fs.File;
