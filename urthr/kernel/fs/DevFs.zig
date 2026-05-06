//! Device filesystem.
//!
//! Implements `fs.FileSystem`.

const Self = @This();

/// Owned allocator for this filesystem.
allocator: Allocator,
/// Root inode of this filesystem.
root_inode: *InodeImpl,
/// Registered device entries.
entries: [max_entries]?DevEntry = [_]?DevEntry{null} ** max_entries,
/// The number of registered devices.
entry_count: usize = 0,

/// Maximum number of devices that can be registered.
const max_entries = 16;

/// Instantiate the device filesystem.
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
            .iops = root_inode_vtable,
            .fops = file_vtable,
        },
        .devfs = self,
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

/// Register a device with the given name and file operations.
pub fn registerDevice(self: *Self, name: []const u8, fops: fs.File.Ops) fs.Error!void {
    rtt.expect(self.entry_count < max_entries);

    const inode = try self.allocator.create(InodeImpl);
    errdefer self.allocator.destroy(inode);
    const name_copy = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(name_copy);

    inode.* = .{
        .common = .{
            .number = self.entry_count + 2,
            .size = 0,
            .ftype = .regular,
            .iops = dev_inode_vtable,
            .fops = fops,
        },
        .devfs = self,
    };
    inode.common.ref();

    self.entries[self.entry_count] = .{
        .name = name_copy,
        .inode = inode,
    };
    self.entry_count += 1;
}

// =============================================================
// Filesystem vtable
// =============================================================

const fs_vtable = fs.FileSystem.Vtable{
    .open = fopen,
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

const DevEntry = struct {
    name: []const u8,
    inode: *InodeImpl,
};

// =============================================================
// Inode interface
// =============================================================

/// devfs specific inode implementation.
pub const InodeImpl = struct {
    /// Common part of the inode.
    common: fs.Inode,
    /// Pointer back to the devfs instance.
    devfs: *Self,

    pub fn from(inode: *fs.Inode) *InodeImpl {
        return @fieldParentPtr("common", inode);
    }
};

/// inode vtable for root directory.
const root_inode_vtable = fs.Inode.Ops{
    .lookup = &iRootLookup,
    .deinit = &ideinit,
};

/// inode vtable for device files.
const dev_inode_vtable = fs.Inode.Ops{
    .lookup = &iDevLookup,
    .deinit = &ideinit,
};

fn iRootLookup(dir: *fs.Inode, name: []const u8) fs.Error!?*fs.Inode {
    const ctx = InodeImpl.from(dir);
    const self = ctx.devfs;

    for (self.entries[0..self.entry_count]) |entry| {
        const e = entry orelse continue;
        if (std.mem.eql(u8, e.name, name)) {
            e.inode.common.ref();
            return &e.inode.common;
        }
    } else return null;
}

fn iDevLookup(_: *fs.Inode, _: []const u8) fs.Error!?*fs.Inode {
    return null;
}

fn ideinit(inode: *fs.Inode) void {
    const ctx = InodeImpl.from(inode);
    ctx.devfs.allocator.destroy(ctx);
}

// =============================================================
// Root directory file vtable
// =============================================================

const file_vtable = fs.File.Ops{
    .iterate = fiterate,
    .read = fread,
    .close = fclose,
};

const FileImpl = struct {
    inode: *InodeImpl,
};

fn fiterate(iter: *fs.File.Iterator, allocator: Allocator) fs.Error!?fs.File.IterResult {
    const ctx: *FileImpl = @ptrCast(@alignCast(iter.file.ctx));
    const self = ctx.inode.devfs;

    if (iter.offset >= self.entry_count) return null;

    const e = self.entries[iter.offset] orelse return null;
    iter.offset += 1;
    return .{
        .name = try allocator.dupe(u8, e.name),
        .inum = e.inode.common.number,
        .type = .regular,
    };
}

fn fread(_: *fs.File, _: []u8, _: usize) fs.Error!usize {
    return fs.Error.NotFile;
}

fn fclose(ctx: *anyopaque, allocator: Allocator) void {
    const file: *FileImpl = @ptrCast(@alignCast(ctx));
    allocator.destroy(file);
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
