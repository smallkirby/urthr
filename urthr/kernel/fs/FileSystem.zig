//! Filesystem interface.
//!
//! This provides a common interface for different filesystem implementations.

const Self = @This();
const FileSystem = Self;
const Error = fs.Error;

/// Type-erased pointer to the filesystem implementation.
ptr: *anyopaque,
/// Vtable for the filesystem interface.
vtable: *const Vtable,

/// Root directory.
root: *Inode,

pub const Vtable = struct {
    /// Get the label of the filesystem.
    getLabel: ?*const fn (*const anyopaque, Allocator) Error![]const u8 = null,
    /// Open the file represented by the given inode.
    open: *const fn (inode: *Inode, allocator: Allocator) Error!*anyopaque,
};

/// Get the label of the filesystem.
///
/// If the backing filesystem does not support this operation, returns `Error.Unsupported`.
pub fn getLabel(self: *const Self, allocator: Allocator) Error![]const u8 {
    if (self.vtable.getLabel) |f| {
        return f(self.ptr, allocator);
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
const Inode = fs.Inode;
