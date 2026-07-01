//! In-memory root filesystem.
//!
//! Implements `fs.FileSystem`.

const Self = @This();

/// Owned allocator for this filesystem.
allocator: Allocator,
/// Root inode of this filesystem.
root_inode: *InodeImpl,
/// Entries created in the root directory.
entries: [max_entries]?DirEntry = [_]?DirEntry{null} ** max_entries,
/// The number of entries currently created in the root directory.
entry_count: usize = 0,

/// Maximum number of entries that can be created in the root directory.
const max_entries = 8;

/// Instantiate the root filesystem.
pub fn init(allocator: Allocator) fs.Error!*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

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
        .rootfs = self,
    };
    root.common.ref();

    self.* = .{
        .allocator = allocator,
        .root_inode = root,
    };
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

// =============================================================
// Filesystem vtable
// =============================================================

const fs_vtable = fs.FileSystem.Vtable{};

const DirEntry = struct {
    /// Name of the directory entry.
    name: []const u8,
    /// Inode associated with this entry.
    inode: *InodeImpl,
};

// =============================================================
// Inode Interface
// =============================================================

const inode_vtable = fs.Inode.Ops{
    .lookup = &ilookup,
    .create = &icreate,
    .deinit = &ideinit,
};

/// rootfs specific inode implementation.
pub const InodeImpl = struct {
    /// Common part of inode.
    common: fs.Inode,
    /// Pointer to the rootfs.
    rootfs: *Self,

    pub fn from(inode: *fs.Inode) *InodeImpl {
        return @fieldParentPtr("common", inode);
    }
};

/// create implementation.
fn icreate(dir: *fs.Inode, name: []const u8, ftype: fs.FileType, allocator: Allocator) fs.Error!*fs.Inode {
    const ctx = InodeImpl.from(dir);
    const self = ctx.rootfs;

    rtt.expectEqual(.directory, dir.ftype);
    rtt.expect(self.entry_count < max_entries);

    const inode = try allocator.create(InodeImpl);
    errdefer allocator.destroy(inode);
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);

    inode.* = .{
        .common = .{
            .number = self.entry_count + 2,
            .size = 0,
            .ftype = ftype,
            .iops = inode_vtable,
            .fops = file_vtable,
        },
        .rootfs = self,
    };
    inode.common.ref();

    self.entries[self.entry_count] = .{
        .name = name_copy,
        .inode = inode,
    };
    self.entry_count += 1;

    return &inode.common;
}

/// Lookup an inode by its name in the root directory.
fn ilookup(dir: *fs.Inode, name: []const u8) fs.Error!?*fs.Inode {
    const ctx = InodeImpl.from(dir);
    const self = ctx.rootfs;

    for (self.entries[0..self.entry_count]) |entry| {
        const e = entry orelse continue;
        if (std.mem.eql(u8, e.name, name)) {
            e.inode.common.ref();
            return &e.inode.common;
        }
    } else return null;
}

/// Deinitialize an inode and release associated resources.
fn ideinit(inode: *fs.Inode) void {
    const ctx = InodeImpl.from(inode);
    ctx.rootfs.allocator.destroy(ctx);
}

// =============================================================
// File vtable
// =============================================================

const file_vtable = fs.File.Ops{
    .open = fopen,
    .iterate = fiterate,
    .read = fread,
    .close = fclose,
    .poll = fpoll,
};

/// rootfs specific file implementation.
const FileImpl = struct {
    inode: *InodeImpl,
};

fn fopen(inode: *fs.Inode, allocator: Allocator) fs.Error!*anyopaque {
    const file = try allocator.create(FileImpl);
    file.* = .{ .inode = InodeImpl.from(inode) };
    return @ptrCast(file);
}

fn fiterate(iter: *fs.File.Iterator, allocator: Allocator) fs.Error!?fs.File.IterResult {
    const ctx: *FileImpl = @ptrCast(@alignCast(iter.file.ctx));
    const self = ctx.inode.rootfs;

    if (iter.offset >= self.entry_count) return null;

    const e = self.entries[iter.offset] orelse return null;
    iter.offset += 1;
    return .{
        .name = try allocator.dupe(u8, e.name),
        .inum = e.inode.common.number,
        .type = .directory,
    };
}

fn fread(_: *fs.File, _: []u8, _: usize) fs.Error!usize {
    return fs.Error.NotFile;
}

fn fclose(ctx: *anyopaque, allocator: Allocator) void {
    const file: *FileImpl = @ptrCast(@alignCast(ctx));
    allocator.destroy(file);
}

fn fpoll(file: *fs.File) fs.Error!fs.PollResult {
    return switch (file.getType()) {
        .regular => .{ .events = .{
            .in = true,
            .out = true,
        } },
        .directory => .{ .events = .none },
    };
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
