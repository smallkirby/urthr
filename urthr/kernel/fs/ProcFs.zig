//! Process Filesystem.
//!
//! Implements `fs.FileSystem`.

const Self = @This();

///////////////////////////////////////////////////////////////
// zig fmt: off

/// Tree of the process file system.
const tree = [_]NodeSpec{
    .file   ("meminfo",     readMeminfo),
    .dir    ("self",        &[_]NodeSpec{
        .symlink    ("exe",      exeReadlink),
    }),
};

// zig fmt: on
///////////////////////////////////////////////////////////////

/// Owned allocator for this filesystem.
allocator: Allocator,
/// Root inode of this filesystem.
root_inode: *InodeImpl,
/// Next inode number to allocate.
///
/// 1 is reserved for the root.
next_inum: fs.Inode.Number = 2,

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
            .iops = dir_inode_vtable,
            .fops = dir_file_vtable,
        },
        .procfs = self,
    };
    root.common.ref();

    self.* = .{
        .allocator = allocator,
        .root_inode = root,
    };

    // Spawn tree structure.
    try self.buildTree(root, &tree);

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
// Tree structure
// =============================================================

/// Process filesystem node descriptor.
const NodeSpec = struct {
    /// Node name.
    name: []const u8,
    /// Node kind.
    kind: Kind,

    const Kind = union(enum) {
        /// Regular file backed by a read function.
        file: ReadFn,
        /// Symbolic link backed by a readlink function.
        symlink: ReadlinkFn,
        /// Subdirectory holding more nodes.
        dir: []const NodeSpec,
    };

    fn file(name: []const u8, read_fn: ReadFn) NodeSpec {
        return .{ .name = name, .kind = .{ .file = read_fn } };
    }

    fn symlink(name: []const u8, readlink_fn: ReadlinkFn) NodeSpec {
        return .{ .name = name, .kind = .{ .symlink = readlink_fn } };
    }

    fn dir(name: []const u8, children: []const NodeSpec) NodeSpec {
        return .{ .name = name, .kind = .{ .dir = children } };
    }
};

/// Register a regular file with the given name under the directory.
fn registerFile(self: *Self, dir: *InodeImpl, name: []const u8, function: ReadFn) fs.Error!void {
    rtt.expect(dir.entry_count < max_entries);

    const inode = try self.allocator.create(InodeImpl);
    errdefer self.allocator.destroy(inode);
    const name_copy = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(name_copy);

    inode.* = .{
        .common = .{
            .number = self.allocInum(),
            .size = 0,
            .ftype = .regular,
            .iops = file_inode_vtable,
            .fops = freg_vtable,
        },
        .procfs = self,
        .read_fn = function,
    };
    inode.common.ref();

    dir.entries[dir.entry_count] = .{
        .name = name_copy,
        .inode = inode,
    };
    dir.entry_count += 1;
}

/// Register a subdirectory with the given name under the directory.
///
/// Returns the newly created subdirectory inode.
fn registerDir(self: *Self, dir: *InodeImpl, name: []const u8) fs.Error!*InodeImpl {
    rtt.expect(dir.entry_count < max_entries);

    const inode = try self.allocator.create(InodeImpl);
    errdefer self.allocator.destroy(inode);
    const name_copy = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(name_copy);

    inode.* = .{
        .common = .{
            .number = self.allocInum(),
            .size = 0,
            .ftype = .directory,
            .iops = dir_inode_vtable,
            .fops = dir_file_vtable,
        },
        .procfs = self,
    };
    inode.common.ref();

    dir.entries[dir.entry_count] = .{
        .name = name_copy,
        .inode = inode,
    };
    dir.entry_count += 1;

    return inode;
}

/// Register a symbolic link with the given name under the directory.
fn registerSymlink(self: *Self, dir: *InodeImpl, name: []const u8, function: ReadlinkFn) fs.Error!void {
    rtt.expect(dir.entry_count < max_entries);

    const inode = try self.allocator.create(InodeImpl);
    errdefer self.allocator.destroy(inode);
    const name_copy = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(name_copy);

    inode.* = .{
        .common = .{
            .number = self.allocInum(),
            .size = 0,
            .ftype = .symlink,
            .iops = symlink_inode_vtable,
            .fops = freg_vtable,
        },
        .procfs = self,
        .readlink_fn = function,
    };
    inode.common.ref();

    dir.entries[dir.entry_count] = .{
        .name = name_copy,
        .inode = inode,
    };
    dir.entry_count += 1;
}

/// Recursively instantiate node tree under the given directory.
fn buildTree(self: *Self, dir: *InodeImpl, specs: []const NodeSpec) fs.Error!void {
    for (specs) |spec| {
        switch (spec.kind) {
            .file => |read_fn| try self.registerFile(
                dir,
                spec.name,
                read_fn,
            ),
            .symlink => |readlink_fn| try self.registerSymlink(
                dir,
                spec.name,
                readlink_fn,
            ),
            .dir => |children| {
                const child = try self.registerDir(
                    dir,
                    spec.name,
                );
                try self.buildTree(child, children);
            },
        }
    }
}

// =============================================================
// Filesystem vtable
// =============================================================

const fs_vtable = fs.FileSystem.Vtable{};

// =============================================================
// Inode interface
// =============================================================

/// Maximum number of entries a single directory can hold.
const max_entries = 32;

/// A directory entry.
const Entry = struct {
    /// File name.
    name: []const u8,
    /// Inode of the file.
    inode: *InodeImpl,
};

/// Read function type for regular file.
const ReadFn = *const fn (buf: []u8, pos: usize) fs.Error!usize;
/// Read function type for a symbolic link.
const ReadlinkFn = *const fn (buf: []u8) fs.Error!usize;

const InodeImpl = struct {
    /// Common part of inode.
    common: fs.Inode,
    /// Pointer to procfs instance.
    procfs: *Self,
    /// Read function for regular files.
    read_fn: ?ReadFn = null,
    /// Read function for symbolic links.
    readlink_fn: ?ReadlinkFn = null,
    /// Child entries of directories.
    entries: [max_entries]?Entry = [_]?Entry{null} ** max_entries,
    /// Number of child entries currently registered.
    entry_count: usize = 0,

    pub fn from(inode: *fs.Inode) *InodeImpl {
        return @fieldParentPtr("common", inode);
    }
};

const dir_inode_vtable = fs.Inode.Ops{
    .lookup = &iDirLookup,
    .deinit = &iDeinit,
};
const file_inode_vtable = fs.Inode.Ops{
    .lookup = &iFileLookup,
    .deinit = &iDeinit,
};
const symlink_inode_vtable = fs.Inode.Ops{
    .lookup = &iFileLookup,
    .deinit = &iDeinit,
    .readlink = &iSymlinkReadlink,
};

/// Lookup implementation shared by all directories.
fn iDirLookup(dir: *fs.Inode, name: []const u8) fs.Error!?*fs.Inode {
    const ctx = InodeImpl.from(dir);

    for (ctx.entries[0..ctx.entry_count]) |entry| {
        const e = entry orelse continue;
        if (std.mem.eql(u8, e.name, name)) {
            e.inode.common.ref();
            return &e.inode.common;
        }
    } else return null;
}

/// Lookup implementation shared by all regular files.
fn iFileLookup(_: *fs.Inode, _: []const u8) fs.Error!?*fs.Inode {
    return null;
}

/// Readlink implementation shared by all symbolic links.
fn iSymlinkReadlink(inode: *fs.Inode, buf: []u8) fs.Error!usize {
    const ctx = InodeImpl.from(inode);
    const f = ctx.readlink_fn orelse return fs.Error.InvalidArgument;
    return f(buf);
}

fn iDeinit(inode: *fs.Inode) void {
    const ctx = InodeImpl.from(inode);
    ctx.procfs.allocator.destroy(ctx);
}

/// Allocate a new, filesystem-wide unique inode number.
fn allocInum(self: *Self) fs.Inode.Number {
    const n = self.next_inum;
    self.next_inum += 1;
    return n;
}

// =============================================================
// Directory file vtable
// =============================================================

const DirFileImpl = struct {
    inode: *InodeImpl,
};

const dir_file_vtable = File.Ops{
    .open = fDirOpen,
    .iterate = fDirIterate,
    .read = fDirRead,
    .close = fDirClose,
    .poll = fDirPoll,
};

fn fDirOpen(inode: *fs.Inode, allocator: Allocator) fs.Error!*anyopaque {
    const file = try allocator.create(DirFileImpl);
    file.* = .{ .inode = InodeImpl.from(inode) };
    return @ptrCast(file);
}

fn fDirIterate(iter: *File.Iterator, allocator: Allocator) fs.Error!?File.IterResult {
    const ctx: *DirFileImpl = @ptrCast(@alignCast(iter.file.ctx));
    const dir = ctx.inode;

    if (iter.offset >= dir.entry_count) {
        return null;
    }

    const e = dir.entries[iter.offset] orelse return null;
    iter.offset += 1;

    return .{
        .name = try allocator.dupe(u8, e.name),
        .inum = e.inode.common.number,
        .type = e.inode.common.ftype,
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
    .open = fRegOpen,
    .iterate = fRegIterate,
    .read = fRegRead,
    .close = fRegClose,
    .poll = fRegPoll,
};

fn fRegOpen(_: *fs.Inode, _: Allocator) fs.Error!*anyopaque {
    return undefined;
}

fn fRegIterate(_: *File.Iterator, _: Allocator) fs.Error!?File.IterResult {
    return fs.Error.NotDirectory;
}

fn fRegRead(file: *File, buf: []u8, pos: usize) fs.Error!usize {
    const inode = InodeImpl.from(file.path.dentry.inode);
    const read_fn = inode.read_fn orelse return 0;
    return read_fn(buf, pos);
}

fn fRegClose(_: *anyopaque, _: Allocator) void {}

fn fRegPoll(_: *File) fs.Error!fs.PollResult {
    return .{ .events = .{ .in = true } };
}

// =============================================================
// Node implementations
// =============================================================

// =============================================================
// /proc/meminfo

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
// /proc/self/exe

fn exeReadlink(buf: []u8) fs.Error!usize {
    return sched.getCurrent().group.getExePath(buf) orelse fs.Error.InvalidArgument;
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
const sched = urd.sched;
