//! inode.
//!
//! Represents a file instance other than its name.

const Self = @This();
const Inode = Self;
const Error = fs.Error;

/// inode operations.
pub const Ops = struct {
    /// Lookup an inode by its name.
    ///
    /// - `dir`: Directory inode to look up.
    /// - `name`: Name of the file to look up.
    ///
    /// Returns an inode that is associated with the found file.
    lookup: *const fn (dir: *Inode, name: []const u8) Error!?*Inode,

    /// Deinitialize the inode and release associated resources.
    ///
    /// Called when the reference count of the inode reaches zero.
    deinit: *const fn (inode: *Inode) void,

    /// Create a new file under `dir` with the given name.
    ///
    /// null if the filesystem does not support file creation.
    create: ?*const fn (dir: *Inode, name: []const u8, ftype: fs.FileType, mode: fs.FileMode, allocator: Allocator) Error!*Inode = null,

    /// Remove the directory entry named `name` under `dir`.
    ///
    /// Implementation must not release the underlying storage of `child`
    /// until the inode is `deinit()`-ed when there's not references to it anymore.
    ///
    /// null if the filesystem does not support file removal.
    unlink: ?*const fn (dir: *Inode, child: *Inode) Error!void = null,

    /// Create a symbolic link under `dir` with the given name pointing to `target`.
    ///
    /// null if the filesystem does not support symbolic links.
    symlink: ?*const fn (dir: *Inode, name: []const u8, target: []const u8, allocator: Allocator) Error!*Inode = null,

    /// Change a permission of the file.
    ///
    /// null if the filesystem does not support changing permission.
    chmod: ?*const fn (inode: *Inode, mode: fs.FileMode) Error!void = null,
};

/// inode number type.
pub const Number = u64;

/// Inode number.
///
/// Unique in a filesystem.
number: Number,
/// File size.
size: usize,
/// File type.
ftype: fs.FileType,
/// Permission granted to this file's owner, group, and others.
mode: fs.FileMode = .{},

/// Inode operations.
iops: Ops,
/// File operations.
fops: File.Ops,
/// Reference count.
refcnt: std.atomic.Value(usize) = .init(0),

/// Lookup an inode by its name.
pub fn lookup(self: *Self, name: []const u8) Error!?*Inode {
    if (self.ftype != .directory) return Error.NotDirectory;

    return self.iops.lookup(self, name);
}

/// Increment the reference count of this inode.
pub fn ref(self: *Self) void {
    _ = self.refcnt.fetchAdd(1, .acq_rel);
}

/// Decrement the reference count of this inode.
///
/// If the count reaches zero, the inode is deallocated and its resources are released.
pub fn unref(self: *Self) void {
    if (self.refcnt.fetchSub(1, .acq_rel) == 1) {
        self.iops.deinit(self);
    }
}

/// Create a directory under this inode with the given name.
pub fn mkdir(self: *Self, name: []const u8, mode: fs.FileMode, allocator: Allocator) Error!*Inode {
    if (self.ftype != .directory) return Error.NotDirectory;

    if (try self.lookup(name)) |_| {
        return Error.AlreadyExists;
    }

    if (self.iops.create) |f| {
        return f(self, name, .directory, mode, allocator);
    } else {
        return Error.Unsupported;
    }
}

/// Create a regular file under this inode with the given name.
pub fn create(self: *Self, name: []const u8, mode: fs.FileMode, allocator: Allocator) Error!*Inode {
    if (self.ftype != .directory) return Error.NotDirectory;

    if (try self.lookup(name)) |_| {
        return Error.AlreadyExists;
    }

    if (self.iops.create) |f| {
        return f(self, name, .regular, mode, allocator);
    } else {
        return Error.Unsupported;
    }
}

/// Change the permission granted to this file.
pub fn chmod(self: *Self, mode: fs.FileMode) Error!void {
    if (self.iops.chmod) |f| {
        try f(self, mode);
    }
    self.mode = mode;
}

/// Create a symbolic link under this inode with the given name, pointing to `target`.
pub fn symlink(self: *Self, name: []const u8, target: []const u8, allocator: Allocator) Error!*Inode {
    if (self.ftype != .directory) return Error.NotDirectory;

    if (try self.lookup(name)) |_| {
        return Error.AlreadyExists;
    }

    if (self.iops.symlink) |f| {
        return f(self, name, target, allocator);
    } else {
        return Error.Unsupported;
    }
}

/// Remove a file entry named `name` under this directory.
pub fn unlink(self: *Self, child: *Inode) Error!void {
    if (self.ftype != .directory) return Error.NotDirectory;

    if (self.iops.unlink) |f| {
        return f(self, child);
    } else {
        return Error.Unsupported;
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;

const urd = @import("urthr");
const fs = urd.fs;
const File = @import("File.zig");
