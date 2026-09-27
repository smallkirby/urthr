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
pub const max_fds = 64;

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
/// Number of threads sharing this instance.
refcnt: usize = 1,
/// Protects access to this table.
_lock: SpinLock = .{},

/// Create a new empty table.
pub fn new(allocator: Allocator) Allocator.Error!*Self {
    const self = try allocator.create(Self);
    self.* = .{};
    return self;
}

/// Increment the reference count to share this instance.
pub fn ref(self: *Self) *Self {
    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);
    self.refcnt += 1;
    return self;
}

/// Get the file associated with the given file descriptor.
///
/// Returns null if the descriptor is not open.
/// The returned file is owned by the caller, who must call `unref()` after use.
pub fn get(self: *Self, fd: usize) Error!?*File {
    if (fd >= max_fds) return Error.InvalidFd;

    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);

    const file = self.entries[fd] orelse return null;
    file.ref();
    return file;
}

/// Assign a file to the given file descriptor.
///
/// Returns error if the slot is already occupied.
/// The table takes a reference on the file.
pub fn set(self: *Self, fd: usize, file: *File) Error!void {
    if (fd >= max_fds) return Error.InvalidFd;

    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);

    if (self.entries[fd] != null) {
        return Error.AlreadyOpen;
    }

    file.ref();
    self.entries[fd] = file;
}

/// Allocate the lowest available file descriptor for the given file.
///
/// Increment the reference count on the file.
/// Returns the allocated descriptor, or error.TableFull if the table is full.
pub fn alloc(self: *Self, file: *File) Error!usize {
    return self.allocAt(0, file, .{});
}

/// Allocate the lowest available file descriptor larger than or equalt to `min_fd` for the given file.
///
/// Increment the reference count on the file.
pub fn allocAt(self: *Self, min_fd: usize, file: *File, flags: FdFlags) Error!usize {
    if (min_fd >= max_fds) return Error.InvalidFd;

    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);

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

/// Atomically install the file at the exactly specified slot, closing whatever was open there.
pub fn replaceAt(self: *Self, fd: usize, file: *File, flags: FdFlags) Error!void {
    if (fd >= max_fds) return Error.InvalidFd;

    const old = blk: {
        const ie = self._lock.lockDisableIrq();
        defer self._lock.unlockRestoreIrq(ie);

        const old = self.entries[fd];
        file.ref();
        self.entries[fd] = file;
        self.fd_flags[fd] = flags;
        break :blk old;
    };
    if (old) |o| o.unref();
}

/// Get the per-descriptor flags of the given file descriptor.
pub fn getFlags(self: *Self, fd: usize) Error!FdFlags {
    if (fd >= max_fds) return Error.InvalidFd;

    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);
    if (self.entries[fd] == null) return Error.InvalidFd;
    return self.fd_flags[fd];
}

/// Set the per-descriptor flags of the given file descriptor.
pub fn setFlags(self: *Self, fd: usize, flags: FdFlags) Error!void {
    if (fd >= max_fds) return Error.InvalidFd;

    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);
    if (self.entries[fd] == null) return Error.InvalidFd;
    self.fd_flags[fd] = flags;
}

/// Close the file descriptor and release the associated file.
pub fn close(self: *Self, fd: usize) Error!void {
    if (fd >= max_fds) return Error.InvalidFd;

    const closed = blk: {
        const ie = self._lock.lockDisableIrq();
        defer self._lock.unlockRestoreIrq(ie);

        const file = self.entries[fd] orelse {
            return Error.InvalidFd;
        };
        self.entries[fd] = null;
        self.fd_flags[fd] = .{};

        break :blk file;
    };

    closed.unref();
}

/// Create an independent copy of this table, taking a reference on each open file.
pub fn clone(self: *Self, allocator: Allocator) Allocator.Error!*Self {
    const cloned = try allocator.create(Self);
    cloned.* = .{};

    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);

    for (self.entries, 0..) |slot, fd| {
        if (slot) |file| {
            file.ref();
            cloned.entries[fd] = file;
            cloned.fd_flags[fd] = self.fd_flags[fd];
        }
    }
    return cloned;
}

/// Drop a reference to this instance, closing all open files and freeing it once unreferenced.
pub fn deinit(self: *Self, allocator: Allocator) void {
    const ie = self._lock.lockDisableIrq();
    const last = self.refcnt == 1;
    self.refcnt -= 1;
    self._lock.unlockRestoreIrq(ie);
    if (!last) return;

    // No other thread can reach this table anymore.
    for (&self.entries) |*slot| {
        if (slot.*) |file| {
            file.unref();
            slot.* = null;
        }
    }
    allocator.destroy(self);
}

// =============================================================
// Imports
// =============================================================

const Allocator = @import("std").mem.Allocator;
const urd = @import("urthr");
const fs = urd.fs;
const File = fs.File;
const SpinLock = urd.sync.SpinLock;
