//! Filesystem abstraction layer.

pub const Fat32 = @import("fs/Fat32.zig");

/// Filesystem-specific errors.
pub const Error = error{
    /// The filesystem type is not recognized or invalid.
    InvalidFilesystem,
    /// The path component is not a directory.
    NotDirectory,
    /// The entry is not a file.
    NotFile,
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
        /// Open a file from an entry.
        openFile: *const fn (ctx: *anyopaque, entry: *const Entry) Error!File,
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

    /// Open a file from an entry.
    pub fn openFile(self: FileSystem, entry: *const Entry) Error!File {
        if (entry.kind != .file) {
            return Error.NotFile;
        }

        return self.vtable.openFile(self.ptr, entry);
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
        /// Close the directory and release associated resources.
        close: *const fn (ctx: *anyopaque) void,
    };

    /// Create an iterator for directory entries.
    ///
    /// The given allocator is used for allocating memory to create directory entry.
    pub fn iterator(self: Directory, allocator: Allocator) Error!Iterator {
        return self.vtable.iterator(self.ptr, allocator);
    }

    /// Close the directory and release associated resources.
    pub fn close(self: Directory) void {
        self.vtable.close(self.ptr);
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
        /// Close the iterator and release associated resources.
        close: *const fn (ctx: *anyopaque) void,
    };

    /// Get the next directory entry.
    ///
    /// Caller must call `close()` to release resources when finished iterating.
    ///
    /// Returns `null` when there are no more entries.
    pub fn next(self: *Iterator) Error!?*Entry {
        return self.vtable.next(self.ptr, self.allocator);
    }

    /// Close the iterator and release associated resources.
    pub fn close(self: Iterator) void {
        self.vtable.close(self.ptr);
    }
};

/// File interface.
pub const File = struct {
    /// Type-erased pointer to the file implementation.
    ptr: *anyopaque,
    /// Vtable for the file interface.
    vtable: *const Vtable,
    /// Current read position in bytes from the start of the file.
    offset: u64,
    /// Total file size in bytes.
    size: u64,

    pub const Vtable = struct {
        /// Read bytes from the file at the given offset into the buffer.
        ///
        /// Returns the number of bytes actually read.
        read: *const fn (ctx: *anyopaque, offset: u64, buffer: []u8) Error!usize,
        /// Close the file and release associated resources.
        close: *const fn (ctx: *anyopaque) void,
    };

    /// Read bytes from the current position into the buffer.
    ///
    /// Advances the internal offset by the number of bytes read.
    /// Returns 0 at EOF.
    pub fn read(self: *File, buffer: []u8) Error!usize {
        if (self.offset >= self.size) return 0;
        const n = try self.vtable.read(self.ptr, self.offset, buffer);
        self.offset += n;
        return n;
    }

    /// Close the file and release associated resources.
    pub fn close(self: File) void {
        self.vtable.close(self.ptr);
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

    /// Free the entry and its name slice.
    ///
    /// The allocator must be the same one that was passed to `Iterator.iterator()`.
    pub fn deinit(self: *const Entry, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.destroy(self);
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const block = common.block;
