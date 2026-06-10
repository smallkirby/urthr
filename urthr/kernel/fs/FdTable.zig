//! File descriptor table.
//!
//! Maps file descriptor numbers to open `File` instances.

const Self = @This();

/// Errors specific to fd table operations.
pub const Error = error{
    /// The file descriptor number is out of range.
    InvalidFd,
    /// The file descriptor slot is already occupied.
    AlreadyOpen,
    /// The file descriptor table is full.
    TableFull,
};

/// Maximum number of open file descriptors per process.
const max_fds = 64;

/// Per-descriptor flags.
pub const FdFlags = packed struct(u32) {
    /// Close this fd on exec.
    cloexec: bool = false,
    /// Reserved.
    _1: u31 = 0,

    const none = FdFlags{};
};

/// File entries.
entries: [max_fds]?*File = .{null} ** max_fds,
/// Per-descriptor flags parallel to entries.
fd_flags: [max_fds]FdFlags = .{FdFlags.none} ** max_fds,

/// Get the file associated with the given file descriptor.
///
/// Returns null if the descriptor is not open.
pub fn get(self: *Self, fd: usize) Error!?*File {
    if (fd >= max_fds) return Error.InvalidFd;
    return self.entries[fd];
}

/// Assign a file to the given file descriptor.
///
/// Returns error if the slot is already occupied.
/// The table takes a reference on the file.
pub fn set(self: *Self, fd: usize, file: *File) Error!void {
    if (fd >= max_fds) return Error.InvalidFd;
    if (self.entries[fd] != null) return Error.AlreadyOpen;

    file.ref();
    self.entries[fd] = file;
}

/// Allocate the lowest available file descriptor for the given file.
///
/// Returns the allocated descriptor, or error.TableFull if the table is full.
pub fn alloc(self: *Self, file: *File) Error!usize {
    return self.allocAt(0, file, .{});
}

/// Allocate the lowest available file descriptor larger than or equalt to `min_fd` for the given file.
pub fn allocAt(self: *Self, min_fd: usize, file: *File, flags: FdFlags) Error!usize {
    for (self.entries[min_fd..], min_fd..) |slot, fd| {
        if (slot == null) {
            file.ref();
            self.entries[fd] = file;
            self.fd_flags[fd] = flags;
            return fd;
        }
    }
    return Error.TableFull;
}

/// Close the file descriptor and release the associated file.
pub fn close(self: *Self, fd: usize) Error!void {
    if (fd >= max_fds) return Error.InvalidFd;

    if (self.entries[fd]) |file| {
        file.unref();
        self.entries[fd] = null;
        self.fd_flags[fd] = .{};
    }
}

/// Close all open file descriptors.
pub fn deinit(self: *Self) void {
    for (&self.entries) |*slot| {
        if (slot.*) |file| {
            file.unref();
            slot.* = null;
        }
    }
}

// =============================================================
// Imports
// =============================================================

const urd = @import("urthr");
const fs = urd.fs;
const File = fs.File;
