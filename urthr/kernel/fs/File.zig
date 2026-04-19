//! Represents a open file entry.

const Self = @This();
const File = Self;
const Error = fs.Error;

pub const Ops = struct {
    /// Iterate over all files in this directory inode.
    ///
    /// This function allocates a memory using the given allocator,
    /// then stores file entries in the allocated buffer.
    /// Caller must free the allocated buffer.
    iterate: *const fn (iter: *Iterator, allocator: Allocator) Error!?IterResult,
    /// Read data from the file at position `pos` to `buf`.
    ///
    /// Return the number of bytes read.
    read: *const fn (self: *File, buf: []u8, pos: usize) Error!usize,
};

/// Context used in `iterate` operation.
pub const IterResult = struct {
    /// Name of the dentry.
    name: []const u8,
    /// inode number.
    inum: Inode.Number,
    /// File type.
    type: fs.FileType,

    pub fn deinit(self: *const IterResult, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

/// Iterator instance.
pub const Iterator = struct {
    /// File this iterator is associated with.
    file: *File,
    /// Current offset in the directory.
    offset: usize,

    /// Get the next file entry in the directory.
    ///
    /// Caller must call `deinit` on the returned result after use.
    pub fn next(self: *Iterator, allocator: Allocator) Error!?IterResult {
        return self.file.ops.iterate(self, allocator);
    }
};

/// Path this file is associated with.
path: Path,
/// File offset.
offset: usize,
/// File operations.
ops: Ops,
/// Reference count.
refcnt: std.atomic.Value(usize) = .init(0),
/// Type-erased pointer to the file instance.
ctx: *anyopaque,
/// Memory allocator.
allocator: Allocator,

/// Open a file at the specified path.
pub fn open(path: fs.Path, allocator: Allocator) Error!*File {
    path.dentry.ref();
    errdefer path.dentry.unref();

    const ctx = try path.mount.?.filesystem.vtable.open(path.dentry.inode, allocator);
    const file = try allocator.create(File);
    file.* = .{
        .path = path,
        .offset = 0,
        .ops = path.dentry.inode.fops,
        .allocator = allocator,
        .ctx = ctx,
    };

    file.ref();
    return file;
}

/// Read data from the file into the buffer.
pub fn read(self: *Self, buf: []u8) Error![]u8 {
    if (self.inode().ftype == .directory) return Error.NotFile;

    const num_read = try self.ops.read(
        self,
        buf,
        self.offset,
    );
    self.offset += @intCast(num_read);

    return buf[0..num_read];
}

/// Create an iterator for this file.
pub fn iterator(self: *Self) Error!Iterator {
    if (self.inode().ftype != .directory) return Error.NotFile;

    return .{
        .file = self,
        .offset = 0,
    };
}

/// Increment the reference count of this file.
pub fn ref(self: *Self) void {
    _ = self.refcnt.fetchAdd(1, .acq_rel);
}

/// Decrement the reference count of this file.
///
/// If the count reaches zero, the file is deallocated and its resources are released.
pub fn unref(self: *Self) void {
    if (self.refcnt.fetchSub(1, .acq_rel) == 1) {
        self.path.dentry.unref();
        self.allocator.destroy(self);
    }
}

/// Helper function to get the inode associated with this file.
fn inode(self: *Self) *Inode {
    return self.path.dentry.inode;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const urd = @import("urthr");
const fs = urd.fs;
const Inode = @import("Inode.zig");
const Path = fs.Path;
