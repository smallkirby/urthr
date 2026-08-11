pub const FileSystem = @import("fs/FileSystem.zig");
pub const Inode = @import("fs/Inode.zig");
pub const Dentry = @import("fs/Dentry.zig");
pub const File = @import("fs/File.zig");
pub const Mount = @import("fs/Mount.zig");

pub const Fat32 = @import("fs/Fat32.zig");
pub const RootFs = @import("fs/RootFs.zig");
pub const DevFs = @import("fs/DevFs.zig");
pub const PipeFs = @import("fs/PipeFs.zig");
pub const SocketFs = @import("fs/SocketFs.zig");
pub const ProcFs = @import("fs/ProcFs.zig");
pub const FdTable = @import("fs/FdTable.zig");

/// Filesystem-specific errors.
pub const Error = error{
    /// A file already exists.
    AlreadyExists,
    /// Attempting to mount on a directory that is already a mount point.
    AlreadyMounted,
    /// The filesystem type is not recognized or invalid.
    InvalidFilesystem,
    /// The path component is not a directory.
    NotDirectory,
    /// The entry is not a file.
    NotFile,
    /// The specified file or directory was not found.
    NotFound,
    /// Filesystem data is corrupted.
    CorruptedData,
    /// The operation is not supported by the filesystem.
    Unsupported,
    /// Write to a pipe with no readers.
    BrokenPipe,
    /// The filesystem is full and cannot accommodate more data.
    NoSpace,
    /// The file was not opened with the access mode required for the operation.
    BadAccess,
    /// The file does not support repositioning the file offset.
    IllegalSeek,
    /// The argument is invalid.
    InvalidArgument,
    /// Operation would block and the file is in non-blocking mode.
    WouldBlock,
    /// Connection refused.
    ///
    /// TODO: should be here?
    ConnectionRefused,
    /// The file descriptor does not refer to a socket.
    NotSocket,
} || block.Error;

pub const max_fds: usize = FdTable.max_fds;

/// File type.
pub const FileType = enum {
    /// Regular file.
    regular,
    /// Directory.
    directory,
    /// Symbolic link.
    symlink,
    /// Socket.
    socket,
};

pub const Path = struct {
    /// Directory entry.
    dentry: *Dentry,
    // Mount this path belongs to.
    mount: ?*Mount,
};

/// Access permission.
pub const Permission = struct {
    /// Readable.
    read: bool = false,
    /// Writable.
    write: bool = false,
    /// Executable.
    exec: bool = false,

    /// Not accessible.
    pub const none = Permission{};
    /// Read-only permission.
    pub const ro = Permission{ .read = true };
    /// Read-write permission.
    pub const rw = Permission{ .read = true, .write = true };
    /// Read-execute permission.
    pub const rx = Permission{ .read = true, .exec = true };
    /// Read-write-execute permission.
    pub const rwx = Permission{ .read = true, .write = true, .exec = true };

    /// Clear the bits set in the given mask.
    pub fn clear(self: Permission, mask: Permission) Permission {
        return .{
            .read = self.read and !mask.read,
            .write = self.write and !mask.write,
            .exec = self.exec and !mask.exec,
        };
    }
};

/// Permission granted to a file's owner, group, and others.
pub const FileMode = struct {
    /// Permission for the file owner.
    user: Permission = .rwx,
    /// Permission for the file's group.
    group: Permission = .rwx,
    /// Permission for others.
    other: Permission = .rwx,

    pub const default = FileMode{
        .user = .none,
        .group = .{ .write = true },
        .other = .{ .write = true },
    };

    /// Apply this mask to a requested file mode, clearing the masked-out bits.
    pub fn apply(self: FileMode, mode: FileMode) FileMode {
        return .{
            .other = mode.other.clear(self.other),
            .group = mode.group.clear(self.group),
            .user = mode.user.clear(self.user),
        };
    }
};

/// I/O readiness events.
pub const PollEvents = packed struct {
    /// Readable data is available.
    in: bool = false,
    /// Urgent data is available.
    urgent: bool = false,
    /// Writable data is available.
    out: bool = false,

    // No events are ready.
    pub const none = PollEvents{};
};

/// Result of a poll operation.
pub const PollResult = struct {
    /// Currently ready events.
    events: PollEvents,
    /// Event to wait on when not ready.
    wait: ?*Event = null,
};

/// Initialize the filesystem subsystem.
///
/// Current thread's root directory is set to the unmounted root.
pub fn init(allocator: Allocator) Error!void {
    // Initialize the empty root.
    const inode = try allocator.create(Inode);
    errdefer allocator.destroy(inode);
    const dentry = try allocator.create(Dentry);
    errdefer allocator.destroy(dentry);

    inode.* = .{
        .number = 0,
        .size = 0,
        .ftype = .directory,
        .iops = undefined,
        .fops = undefined,
    };
    inode.ref();
    dentry.* = .{
        .name = "",
        .inode = inode,
        .parent = null,
        .allocator = allocator,
    };
    dentry.ref();

    const current = sched.getCurrent();
    current.fs.root = .{ .dentry = dentry, .mount = null };
    current.fs.cwd = .{ .dentry = dentry, .mount = null };
    current.fs.umask = .default;

    // Initialize the dentry cache.
    dcache = Dentry.Cache.new(allocator);
    // Initialize the pipe filesystem.
    pipefs = try PipeFs.init(allocator);
    // Initialize the socket filesystem.
    socketfs = try SocketFs.init(allocator);
}

/// Create a new pipe and return its read and write file objects.
pub fn createPipe() Error!PipeFs.PipePair {
    return pipefs.createPipe();
}

/// Create a new socket file wrapping the given protocol-specific descriptor.
///
/// The created socket is backed by the given protocol backend.
/// The backend can identify the socket instance by the given opaque descriptor.
pub fn createSocket(backend: *const SocketFs.Backend, desc: usize) Error!*File {
    return socketfs.createSocket(backend, desc);
}

/// Mount a filesystem to the specified path.
pub fn mount(path: Path, fs: FileSystem, allocator: Allocator) Error!void {
    if (path.dentry.inode.ftype != .directory) {
        return Error.NotDirectory;
    }
    if (path.dentry.mount != null) {
        return Error.AlreadyMounted;
    }

    fs.root.ref();
    errdefer fs.root.unref();

    // Create a new dentry for the root of the mounted filesystem.
    const root = try allocator.create(Dentry);
    root.* = .{
        .name = try allocator.dupe(u8, ""),
        .inode = fs.root,
        .parent = null,
        .allocator = allocator,
    };
    root.ref();
    errdefer root.unref();

    // Attach the new mount to the mount point.
    const mnt = try allocator.create(Mount);
    errdefer allocator.destroy(mnt);
    mnt.* = .{
        .filesystem = fs,
        .root = root,
        .parent = path.mount,
        .mntpoint = path.dentry,
    };
    path.dentry.mount = mnt;
}

/// Create a directory under the given directory with the given name.
pub fn mkdirAt(dir: Path, name: []const u8, mode: FileMode, allocator: Allocator) Error!*Inode {
    var cur = dir;
    if (cur.dentry.mount) |mnt| {
        cur = .{ .dentry = mnt.root, .mount = mnt };
    }

    const inode = try cur.dentry.inode.mkdir(
        name,
        mode,
        allocator,
    );

    // Put the new directory into the dentry cache.
    const dentry = Dentry.create(
        name,
        inode,
        cur.dentry,
        allocator,
    ) catch |err| {
        inode.unref();
        return err;
    };
    errdefer dentry.unref();
    try dcache.insert(dentry);

    return inode;
}

/// Create a directory at the specified path.
pub fn mkdir(s: []const u8, mode: FileMode, allocator: Allocator) Error!*Inode {
    const basename = std.fs.path.basenamePosix(s);
    if (basename.len == 0) {
        return Error.AlreadyExists;
    }

    // Lookup parent directory.
    const dir = if (std.fs.path.dirnamePosix(s)) |dirname|
        try resolvePath(sched.getCurrent().fs.cwd, dirname, allocator)
    else
        sched.getCurrent().fs.cwd;

    return mkdirAt(dir, basename, mode, allocator);
}

/// Create a symbolic link under the given directory with the given name pointing to `target`.
pub fn symlinkAt(dir: Path, name: []const u8, target: []const u8, allocator: Allocator) Error!*Inode {
    var cur = dir;
    if (cur.dentry.mount) |mnt| {
        cur = .{ .dentry = mnt.root, .mount = mnt };
    }

    const inode = try cur.dentry.inode.symlink(
        name,
        target,
        allocator,
    );

    // Put the new symlink into the dentry cache.
    const dentry = Dentry.create(
        name,
        inode,
        cur.dentry,
        allocator,
    ) catch |err| {
        inode.unref();
        return err;
    };
    errdefer dentry.unref();
    try dcache.insert(dentry);

    return inode;
}

/// Create a symbolic link pointing to `target` at the specified path.
pub fn symlink(target: []const u8, linkpath: []const u8, allocator: Allocator) Error!*Inode {
    const basename = std.fs.path.basenamePosix(linkpath);
    if (basename.len == 0) {
        return Error.InvalidArgument;
    }

    // Lookup parent directory.
    const dir = if (std.fs.path.dirnamePosix(linkpath)) |dirname|
        try resolvePath(sched.getCurrent().fs.cwd, dirname, allocator)
    else
        sched.getCurrent().fs.cwd;

    return symlinkAt(dir, basename, target, allocator);
}

/// Create a new regular file at the specified path and open it.
pub fn create(s: []const u8, mode: FileMode, access: File.AccessMode, allocator: Allocator) Error!*File {
    const basename = std.fs.path.basenamePosix(s);
    if (basename.len == 0) {
        return Error.InvalidArgument;
    }

    // Lookup parent directory.
    const dir = if (std.fs.path.dirnamePosix(s)) |dirname|
        try resolvePath(sched.getCurrent().fs.cwd, dirname, allocator)
    else
        sched.getCurrent().fs.cwd;

    return createAt(dir, basename, mode, access, allocator);
}

/// Create a new regular file at the specified directory and open it.
pub fn createAt(dir: Path, basename: []const u8, mode: FileMode, access: File.AccessMode, allocator: Allocator) Error!*File {
    var cur = dir;
    if (cur.dentry.mount) |mnt| {
        cur = .{ .dentry = mnt.root, .mount = mnt };
    }

    if (cur.dentry.inode.ftype != .directory) {
        return Error.NotDirectory;
    }

    // Create new file in the directory.
    const inode = try cur.dentry.inode.create(
        basename,
        mode,
        allocator,
    );

    // Put the new file into dentry cache.
    const dentry = Dentry.create(
        basename,
        inode,
        cur.dentry,
        allocator,
    ) catch |err| {
        inode.unref();
        return err;
    };
    errdefer dentry.unref();
    try dcache.insert(dentry);

    return File.open(
        .{
            .dentry = dentry,
            .mount = cur.mount,
        },
        access,
        allocator,
    );
}

/// Resolve a path to a Path without opening a File.
///
/// Caller must call `path.dentry.unref()` after use.
pub fn resolve(s: []const u8, allocator: Allocator) Error!Path {
    const path = try resolvePath(sched.getCurrent().fs.cwd, s, allocator);
    path.dentry.ref();

    return path;
}

/// Build the absolute path string for a given Path.
///
/// Caller must free the returned slice after use.
pub fn getPath(path: Path, allocator: Allocator) Error![]u8 {
    var components: std.ArrayList([]const u8) = .empty;
    defer components.deinit(allocator);

    var cur_dentry = path.dentry;
    var cur_mount = path.mount;

    while (true) {
        try components.append(allocator, cur_dentry.name);

        if (cur_mount) |mnt| {
            if (cur_dentry == mnt.root) {
                if (mnt.parent) |parent_mnt| {
                    // Cross mount boundary upward.
                    cur_dentry = mnt.mntpoint;
                    cur_mount = parent_mnt;
                    continue;
                } else {
                    break;
                }
            }
        }

        cur_dentry = cur_dentry.parent orelse break;
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '/');

    // Iterate conmponents in reverse.
    var i = components.items.len;
    while (i > 0) {
        i -= 1;
        const name = components.items[i];
        if (name.len == 0) continue;
        try buf.appendSlice(allocator, name);
        try buf.append(allocator, '/');
    }

    // Remove trailing slash unless the path is root.
    if (buf.items.len > 1) _ = buf.pop();

    return buf.toOwnedSlice(allocator);
}

/// Open a file at the specified path.
pub fn open(s: []const u8, access: File.AccessMode, allocator: Allocator) Error!*File {
    const path = try resolvePath(sched.getCurrent().fs.cwd, s, allocator);
    return File.open(path, access, allocator);
}

/// Open a file relative to a directory.
pub fn openAt(dir: Path, s: []const u8, access: File.AccessMode, allocator: Allocator) Error!*File {
    if (std.fs.path.isAbsolute(s)) {
        return Error.InvalidArgument;
    }
    if (dir.dentry.inode.ftype != .directory) {
        return Error.NotDirectory;
    }

    const path = try resolvePath(dir, s, allocator);
    return File.open(path, access, allocator);
}

/// Remove a regular file at the specified path.
///
/// The directory entry is removed immediately,
/// but the underlying storage is only reclaimed once the last open file referring to it is closed.
pub fn unlink(s: []const u8, allocator: Allocator) Error!void {
    const cwd = sched.getCurrent().fs.cwd;
    const path = try resolvePath(cwd, s, allocator);
    return unlinkImpl(path, s);
}

/// Remove a regular file relative to a directory.
///
/// The directory entry is removed immediately,
/// but the underlying storage is only reclaimed once the last open file referring to it is closed.
pub fn unlinkAt(dir: Path, s: []const u8, allocator: Allocator) Error!void {
    if (std.fs.path.isAbsolute(s)) {
        return Error.InvalidArgument;
    }
    if (dir.dentry.inode.ftype != .directory) {
        return Error.NotDirectory;
    }

    const path = try resolvePath(dir, s, allocator);
    return unlinkImpl(path, s);
}

/// Detach the directory entry.
fn unlinkImpl(path: Path, s: []const u8) Error!void {
    if (path.dentry.inode.ftype != .regular) {
        return Error.NotFile;
    }

    // A regular file always has a parent.
    const parent_dentry = path.dentry.parent.?;
    const basename = std.fs.path.basenamePosix(s);

    try parent_dentry.inode.unlink(path.dentry.inode);
    dcache.remove(parent_dentry, basename);
}

/// Resolve a file path to a `Path`.
fn resolvePath(base: Path, s: []const u8, allocator: Allocator) Error!Path {
    var cur: Path = if (std.fs.path.isAbsolutePosix(s))
        sched.getCurrent().fs.root
    else
        base;
    // Whether `cur.dentry` holds a reference acquired by this function.
    var owned = false;

    if (cur.dentry.mount) |mnt| {
        cur = .{ .dentry = mnt.root, .mount = mnt };
    }

    var iter = ComponentIterator.init(s);
    while (iter.next()) |c| {
        if (std.mem.eql(u8, ".", c.name)) continue;

        if (std.mem.eql(u8, "..", c.name)) {
            if (cur.mount) |mnt| {
                if (cur.dentry == mnt.root) {
                    // At the root of a mount.
                    if (mnt.parent) |parent_mnt| {
                        const parent_dentry = mnt.mntpoint.parent orelse mnt.mntpoint;
                        if (owned) cur.dentry.unref();
                        cur = .{ .dentry = parent_dentry, .mount = parent_mnt };
                        owned = false;
                    } else {
                        // Reached the root of root filesystem. Stay here.
                    }
                    continue;
                }
            }

            const parent_dentry = cur.dentry.parent orelse cur.dentry;
            if (owned) cur.dentry.unref();
            cur = .{ .dentry = parent_dentry, .mount = cur.mount };
            owned = false;
            continue;
        }

        // Check if the current dentry is a mount point.
        if (cur.dentry.mount) |mnt| {
            if (owned) cur.dentry.unref();
            cur = .{ .dentry = mnt.root, .mount = mnt };
            owned = false;
        }

        // Check dcache first.
        if (dcache.lookup(cur.dentry, c.name)) |d| {
            if (owned) cur.dentry.unref();
            cur = .{ .dentry = d, .mount = cur.mount };
            owned = true;
            continue;
        }

        // Look up the child dentry.
        if (cur.dentry.inode.ftype != .directory) {
            return Error.NotDirectory;
        }
        const child = try cur.dentry.inode.lookup(c.name) orelse {
            return Error.NotFound;
        };

        // Create a new dentry and insert it into the cache.
        const dentry = try Dentry.create(c.name, child, cur.dentry, allocator);
        try dcache.insert(dentry);

        if (owned) cur.dentry.unref();
        cur = .{ .dentry = dentry, .mount = cur.mount };
        owned = true;
    }

    // Handle the case where the final path component is itself a mount point.
    if (cur.dentry.mount) |mnt| {
        if (owned) cur.dentry.unref();
        cur = .{ .dentry = mnt.root, .mount = mnt };
        owned = false;
    }

    // Drop the transient reference acquired while resolving.
    if (owned) cur.dentry.unref();

    return cur;
}

// =============================================================
// Path resolution
// =============================================================

const ComponentIterator = std.fs.path.ComponentIterator(.posix, u8);

/// dentry cache instance.
var dcache: Dentry.Cache = undefined;

// =============================================================
// Anonymous filesystems
// =============================================================

/// pipefs instance.
var pipefs: *PipeFs = undefined;

/// socketfs instance.
var socketfs: *SocketFs = undefined;

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.fs);
const Allocator = std.mem.Allocator;
const common = @import("common");
const block = common.block;
const urd = @import("urthr");
const sched = urd.sched;
const Event = urd.sync.Event;
