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
/// Whether name lookups under this filesystem ignore case.
case_insensitive: bool = false,

pub const Vtable = struct {
    /// Get the label of the filesystem.
    getLabel: ?*const fn (*const anyopaque, Allocator) Error![]const u8 = null,
    /// Write back all dirty data to the backing store.
    sync: ?*const fn (*anyopaque) Error!void = null,
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

/// Write back all dirty data to the backing store.
pub fn sync(self: *const Self) Error!void {
    if (self.vtable.sync) |f| {
        try f(self.ptr);
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
