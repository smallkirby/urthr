pub const Fat32 = @import("fs/Fat32.zig");

pub const FileSystem = @import("fs/FileSystem.zig");
pub const Inode = @import("fs/Inode.zig");

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

/// File type.
pub const FileType = enum {
    /// Regular file.
    regular,
    /// Directory.
    directory,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const block = common.block;
