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

    /// Change the owner user and/or group of the file.
    ///
    /// A null UID and GID should leave the corresponding ID unchanged.
    ///
    /// null if the filesystem does not support changing ownership.
    chown: ?*const fn (inode: *Inode, uid: ?u32, gid: ?u32) Error!void = null,

    /// Persist the inode's current timestamps to the backing storage.
    ///
    /// null if the filesystem does not persist timestamps.
    utimes: ?*const fn (inode: *Inode) Error!void = null,

    /// Move `child` named `old_name` under `dir` to `new_name` under `new_dir`.
    ///
    /// `replaced` is an existing inode at the destination that must be atomically replaced.
    ///
    /// null if the filesystem does not support renaming entries.
    rename: ?*const fn (dir: *Inode, old_name: []const u8, child: *Inode, new_dir: *Inode, new_name: []const u8, replaced: ?*Inode) Error!void = null,

    /// Remove the empty subdirectory.
    ///
    /// Caller must ensure that `child` is empty.
    /// Implementation must not release the underlying storage of `child`
    /// until the inode is `deinit()`-ed when there's no references to it anymore.
    ///
    /// null if the filesystem does not support directory removal.
    rmdir: ?*const fn (dir: *Inode, child: *Inode) Error!void = null,
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
/// User ID of the owner.
uid: u32 = 0,
/// Group ID of the owner.
gid: u32 = 0,
/// Access, modification, and status-change timestamps.
times: fs.Times = .{},

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
        const inode = try f(
            self,
            name,
            .directory,
            mode,
            allocator,
        );
        if (inode.times.none()) inode.times = .now();
        return inode;
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
        const inode = try f(
            self,
            name,
            .regular,
            mode,
            allocator,
        );
        if (inode.times.none()) inode.times = .now();
        return inode;
    } else {
        return Error.Unsupported;
    }
}

/// Change the permission granted to this file.
pub fn chmod(self: *Self, mode: fs.FileMode) Error!void {
    if (self.iops.chmod) |f| {
        try f(self, mode);
    }
    // Update in-memory state.
    self.mode = mode;
    self.times.ctime = .now();
    // Update on-disk timestamps.
    try self.persistTimes();
}

/// Change the owner user and/or group of this file.
///
/// A null argument leaves the corresponding ID unchanged.
pub fn chown(self: *Self, uid: ?u32, gid: ?u32) Error!void {
    if (self.iops.chown) |f| {
        try f(self, uid, gid);
    }
    // Update in-memory state.
    if (uid) |v| self.uid = v;
    if (gid) |v| self.gid = v;
    self.times.ctime = .now();
    // Update on-disk timestamps.
    try self.persistTimes();
}

/// Update the file's timestamps.
///
/// Timestamp specified as null does not change.
pub fn utimes(self: *Self, atime: ?fs.Timestamp, mtime: ?fs.Timestamp) Error!void {
    if (atime) |v| self.times.atime = v;
    if (mtime) |v| self.times.mtime = v;
    // Update in-memory state.
    self.times.ctime = .now();
    // Update on-disk timestamps.
    try self.persistTimes();
}

/// Create a symbolic link under this inode with the given name, pointing to `target`.
pub fn symlink(self: *Self, name: []const u8, target: []const u8, allocator: Allocator) Error!*Inode {
    if (self.ftype != .directory) return Error.NotDirectory;

    if (try self.lookup(name)) |_| {
        return Error.AlreadyExists;
    }

    if (self.iops.symlink) |f| {
        const inode = try f(
            self,
            name,
            target,
            allocator,
        );
        if (inode.times.none()) inode.times = .now();
        return inode;
    } else {
        return Error.Unsupported;
    }
}

/// Move `child` named `old_name` under `dir` to `new_name` under `new_dir`.
pub fn rename(self: *Self, old_name: []const u8, child: *Inode, new_dir: *Inode, new_name: []const u8, replaced: ?*Inode) Error!void {
    if (self.ftype != .directory) return Error.NotDirectory;
    if (new_dir.ftype != .directory) return Error.NotDirectory;

    if (self.iops.rename) |f| {
        try f(
            self,
            old_name,
            child,
            new_dir,
            new_name,
            replaced,
        );
        // Update in-memory state.
        child.times.ctime = .now();
        // Update on-disk timestamps.
        try child.persistTimes();
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

/// Remove the empty subdirectory from this directory.
///
/// Caller must ensure that `child` is empty.
pub fn rmdir(self: *Self, child: *Inode) Error!void {
    if (self.ftype != .directory) return Error.NotDirectory;

    if (self.iops.rmdir) |f| {
        return f(self, child);
    } else {
        return Error.Unsupported;
    }
}

// =============================================================
// Helpers
// =============================================================

/// Persist the inode's current timestamps.
fn persistTimes(self: *Self) Error!void {
    if (self.iops.utimes) |f| {
        try f(self);
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
