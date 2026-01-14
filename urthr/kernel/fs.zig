//! Filesystem abstraction layer.

pub const Fat32 = @import("fs/Fat32.zig");

/// Filesystem-specific errors.
pub const Error = error{
    /// The filesystem type is not recognized or invalid.
    InvalidFilesystem,
    /// The path component is not a directory.
    NotDirectory,
    /// Filesystem data is corrupted.
    CorruptedData,
} || block.Error;

/// Filesystem interface.
///
/// This provides a common interface for different filesystem implementations.
pub const FileSystem = struct {
    /// Type-erased pointer to the filesystem implementation.
    ptr: *anyopaque,
    /// Vtable for the filesystem interface.
    vtable: *const Vtable,

    pub const Vtable = struct {
        /// Get the root directory of the filesystem.
        getRootDir: *const fn (ctx: *anyopaque) Error!Directory,
        /// Open a directory from an entry.
        openDir: *const fn (ctx: *anyopaque, entry: *const Entry) Error!Directory,
    };

    /// Get the root directory of the filesystem.
    pub fn getRootDir(self: FileSystem) Error!Directory {
        return self.vtable.getRootDir(self.ptr);
    }

    /// Open a directory from an entry.
    pub fn openDir(self: FileSystem, entry: *const Entry) Error!Directory {
        if (entry.kind != .directory) {
            return Error.NotDirectory;
        }

        return self.vtable.openDir(self.ptr, entry);
    }
};

/// Directory interface.
pub const Directory = struct {
    /// Type-erased pointer to the directory implementation.
    ptr: *anyopaque,
    /// Vtable for the directory interface.
    vtable: *const Vtable,

    pub const Vtable = struct {
        /// Create an iterator for directory entries.
        ///
        /// Iterator can own the given allocator for allocating memory for directory entries.
        iterator: *const fn (ctx: *anyopaque, allocator: Allocator) Error!Iterator,
    };

    /// Create an iterator for directory entries.
    ///
    /// The given allocator is used for allocating memory to create directory entry.
    pub fn iterator(self: Directory, allocator: Allocator) Error!Iterator {
        return self.vtable.iterator(self.ptr, allocator);
    }
};

/// Directory entry iterator.
pub const Iterator = struct {
    /// Type-erased pointer to the iterator implementation.
    ptr: *anyopaque,
    /// Vtable for the iterator.
    vtable: *const Vtable,
    /// Memory allocator.
    allocator: Allocator,

    pub const Vtable = struct {
        /// Get the next directory entry.
        ///
        /// Returns `null` when there are no more entries.
        next: *const fn (ctx: *anyopaque, allocator: Allocator) Error!?*Entry,
    };

    /// Get the next directory entry.
    ///
    /// Returns `null` when there are no more entries.
    pub fn next(self: *Iterator) Error!?*Entry {
        return self.vtable.next(self.ptr, self.allocator);
    }
};

/// Directory entry information.
pub const Entry = struct {
    /// Entry name.
    name: []const u8,
    /// Entry type.
    kind: Kind,
    /// File size in bytes (0 for directories).
    size: u64,
    /// Filesystem-specific handle to identify the entry.
    handle: u64,

    /// Directory entry kind.
    pub const Kind = enum {
        /// Regular file.
        file,
        /// Directory.
        directory,
    };
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const block = common.block;
