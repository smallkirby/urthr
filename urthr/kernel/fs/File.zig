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
    iterate: *const fn (self: *File, allocator: Allocator) Error![]IterResult,
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

    pub fn deinit(self: *IterResult, allocator: Allocator) void {
        allocator.free(self.name);
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

/// Arbitrary context.
ctx: ?*anyopaque,
/// Memory allocator.
allocator: Allocator,

/// Create a new file instance.
///
/// Variable entry is zero initialized.
pub fn new(path: fs.Path, allocator: Allocator) Error!*File {
    path.dentry.ref();
    errdefer path.dentry.unref();

    const file = try allocator.create(File);
    file.* = std.mem.zeroInit(File, .{
        .path = path,
        .ops = path.dentry.inode.fops,
        .allocator = allocator,
    });

    file.ref();
    return file;
}

/// Read data from the file into the buffer.
pub fn read(self: *Self, buf: []u8) Error!usize {
    if (self.inode().ftype == .directory) return Error.NotFile;

    const num_read = try self.ops.read(
        self,
        buf,
        self.offset,
    );
    self.offset += @intCast(num_read);

    return num_read;
}

/// Get children of the directory.
///
/// Caller must call `deinit()` for each entry after use.
pub fn iterate(self: *Self, allocator: Allocator) Error![]IterResult {
    if (self.inode().ftype != .directory) return Error.NotFile;

    return try self.ops.iterate(self, allocator);
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
