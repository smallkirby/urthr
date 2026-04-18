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

/// Operations for this inode.
ops: Ops,
/// Reference count.
refcnt: std.atomic.Value(usize) = .init(0),

/// Lookup an inode by its name.
pub fn lookup(self: *Self, name: []const u8) Error!?*Inode {
    if (self.ftype != .directory) return Error.NotDirectory;

    return self.ops.lookup(self, name);
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
        self.ops.deinit(self);
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");

const urd = @import("urthr");
const fs = urd.fs;
