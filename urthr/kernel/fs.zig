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
    /// The directory is not empty.
    NotEmpty,
    /// Cannot operate on the resource.
    Busy,
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
    /// The source and destination are on different filesystems.
    CrossDevice,
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

/// Timestamp in nanoseconds since the UNIX epoch.
pub const Timestamp = struct {
    /// Nanoseconds since the epoch.
    ns: u64,

    /// The zero timestamp.
    pub const zero = Timestamp{ .ns = 0 };

    /// The current time.
    pub fn now() Timestamp {
        return .{ .ns = urd.time.getRealtime() };
    }

    /// Build a timestamp from the given time.
    pub fn from(sec: i64, nsec: i64) error{InvalidArgument}!Timestamp {
        if (sec < 0 or nsec < 0 or nsec >= std.time.ns_per_s) {
            return error.InvalidArgument;
        }
        const s: u64 = @intCast(sec);
        const n: u64 = @intCast(nsec);
        if (s > (std.math.maxInt(u64) - n) / std.time.ns_per_s) {
            // Overflow.
            return error.InvalidArgument;
        }
        return .{ .ns = s * std.time.ns_per_s + n };
    }

    /// Split into a pair of seconds and nanoseconds.
    pub fn to(self: Timestamp) struct { sec: i64, nsec: i64 } {
        return .{
            .sec = @intCast(self.ns / std.time.ns_per_s),
            .nsec = @intCast(self.ns % std.time.ns_per_s),
        };
    }

    pub fn none(self: Timestamp) bool {
        return std.meta.eql(self, .zero);
    }
};

/// Timestamps.
pub const Times = struct {
    /// Time of last access.
    atime: Timestamp = .zero,
    /// Time of last modification.
    mtime: Timestamp = .zero,
    /// Time of last status change.
    ctime: Timestamp = .zero,

    /// Create new timestamps with all fields set to the current time.
    pub fn now() Times {
        const t = Timestamp.now();
        return .{
            .atime = t,
            .mtime = t,
            .ctime = t,
        };
    }

    /// Check if all timestamps are zero.
    pub fn none(self: Times) bool {
        return self.ctime.none() and self.mtime.none() and self.atime.none();
    }
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
    /// Special mode flags.
    flags: Flags = .none,

    pub const default = FileMode{
        .user = .none,
        .group = .{ .write = true },
        .other = .{ .write = true },
    };

    /// Special file mode flags.
    pub const Flags = struct {
        /// Sticky bit.
        sticky: bool = false,
        /// Set-group-ID.
        sgid: bool = false,
        /// Set-user-ID.
        suid: bool = false,

        pub const none = Flags{};
    };

    /// Apply this mask to a requested file mode, clearing the masked-out bits.
    pub fn apply(self: FileMode, mode: FileMode) FileMode {
        return .{
            .other = mode.other.clear(self.other),
            .group = mode.group.clear(self.group),
            .user = mode.user.clear(self.user),
            .flags = mode.flags,
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
pub fn mkdirAt(dir: Path, path: []const u8, mode: FileMode, allocator: Allocator) Error!*Inode {
    const parent, const basename = try resolveParent(
        dir,
        path,
        allocator,
    );
    if (basename.len == 0) {
        return Error.AlreadyExists;
    }

    var cur = parent;
    if (cur.dentry.mount) |mnt| {
        cur = .{ .dentry = mnt.root, .mount = mnt };
    }

    const inode = try cur.dentry.inode.mkdir(
        basename,
        mode,
        allocator,
    );

    // Put the new directory into the dentry cache.
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

    return inode;
}

/// Create a directory at the specified path.
pub fn mkdir(s: []const u8, mode: FileMode, allocator: Allocator) Error!*Inode {
    return mkdirAt(
        sched.getCurrent().fs.cwd,
        s,
        mode,
        allocator,
    );
}

/// Create a symbolic link under the given directory with the given name pointing to `target`.
pub fn symlinkAt(dir: Path, linkpath: []const u8, target: []const u8, allocator: Allocator) Error!*Inode {
    const parent, const basename = try resolveParent(
        dir,
        linkpath,
        allocator,
    );
    if (basename.len == 0) {
        return Error.InvalidArgument;
    }

    var cur = parent;
    if (cur.dentry.mount) |mnt| {
        cur = .{ .dentry = mnt.root, .mount = mnt };
    }

    const inode = try cur.dentry.inode.symlink(
        basename,
        target,
        allocator,
    );

    // Put the new symlink into the dentry cache.
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

    return inode;
}

/// Create a symbolic link pointing to `target` at the specified path.
pub fn symlink(target: []const u8, linkpath: []const u8, allocator: Allocator) Error!*Inode {
    return symlinkAt(
        sched.getCurrent().fs.cwd,
        linkpath,
        target,
        allocator,
    );
}

/// Create a new regular file under the specified directory and open it.
pub fn createAt(dir: Path, path: []const u8, mode: FileMode, access: File.AccessMode, allocator: Allocator) Error!*File {
    const parent, const basename = try resolveParent(
        dir,
        path,
        allocator,
    );
    if (basename.len == 0) {
        return Error.InvalidArgument;
    }

    var cur = parent;
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

/// Create a new regular file at the specified path and open it.
pub fn create(s: []const u8, mode: FileMode, access: File.AccessMode, allocator: Allocator) Error!*File {
    return createAt(
        sched.getCurrent().fs.cwd,
        s,
        mode,
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

/// Remove an empty directory at the specified path.
pub fn rmdir(s: []const u8, allocator: Allocator) Error!void {
    const cwd = sched.getCurrent().fs.cwd;
    const path = try resolvePath(cwd, s, allocator);
    return rmdirImpl(path, s, allocator);
}

/// Remove an empty directory relative to a directory.
pub fn rmdirAt(dir: Path, s: []const u8, allocator: Allocator) Error!void {
    if (std.fs.path.isAbsolute(s)) {
        return Error.InvalidArgument;
    }
    if (dir.dentry.inode.ftype != .directory) {
        return Error.NotDirectory;
    }

    const path = try resolvePath(dir, s, allocator);
    return rmdirImpl(path, s, allocator);
}

/// Detach the directory entry for an empty directory.
fn rmdirImpl(path: Path, s: []const u8, allocator: Allocator) Error!void {
    if (path.dentry.inode.ftype != .directory) {
        return Error.NotDirectory;
    }

    const basename = std.fs.path.basenamePosix(s);
    if (std.mem.eql(u8, ".", basename) or std.mem.eql(u8, "..", basename)) {
        return Error.InvalidArgument;
    }

    // The root of a filesystem has no parent.
    const parent_dentry = path.dentry.parent orelse return Error.Busy;
    // Something else is mounted on top of this directory.
    if (path.dentry.mount != null) {
        return Error.Busy;
    }

    if (!try isEmptyDir(path, allocator)) {
        return Error.NotEmpty;
    }

    try parent_dentry.inode.rmdir(path.dentry.inode);
    dcache.remove(parent_dentry, basename);
}

/// Check whether a directory has no entries.
fn isEmptyDir(path: Path, allocator: Allocator) Error!bool {
    const file = try File.open(path, .{
        .readable = true,
        .writable = false,
    }, allocator);
    defer file.unref();

    var iter = try file.iterator();
    if (try iter.next(allocator)) |ent| {
        ent.deinit(allocator);
        return false;
    }
    return true;
}

/// Move a directory entry to the specified directory with a new name.
///
/// If the new name already exists, it is replaced atomically.
pub fn renameAt(old_dir: Path, old_name: []const u8, new_dir: Path, new_name: []const u8, allocator: Allocator) Error!void {
    if (std.mem.eql(u8, ".", old_name) or std.mem.eql(u8, "..", old_name) or
        std.mem.eql(u8, ".", new_name) or std.mem.eql(u8, "..", new_name))
    {
        return Error.InvalidArgument;
    }

    var old_cur = old_dir;
    var new_cur = new_dir;
    if (old_cur.dentry.mount) |mnt| old_cur = .{
        .dentry = mnt.root,
        .mount = mnt,
    };
    if (new_cur.dentry.mount) |mnt| new_cur = .{
        .dentry = mnt.root,
        .mount = mnt,
    };
    if (old_cur.dentry.inode.ftype != .directory) return Error.NotDirectory;
    if (new_cur.dentry.inode.ftype != .directory) return Error.NotDirectory;
    if (old_cur.mount != new_cur.mount) return Error.CrossDevice;

    // The source must exist.
    const old_path = try resolvePath(old_cur, old_name, allocator);
    // The destination may or may not exist.
    const dst_path: ?Path = resolvePath(new_cur, new_name, allocator) catch |err| switch (err) {
        Error.NotFound => null,
        else => return err,
    };

    // Renaming an entry onto itself is a no-op.
    if (dst_path) |d| {
        if (d.dentry == old_path.dentry) return;
    }

    // Check file type consistency.
    const src_ftype = old_path.dentry.inode.ftype;
    if (dst_path) |d| {
        const dst_ftype = d.dentry.inode.ftype;
        if (src_ftype == .directory and dst_ftype != .directory) return Error.NotDirectory;
        if (src_ftype != .directory and dst_ftype == .directory) return Error.NotFile;
        // Replacing an existing directory would require removing it.
        if (dst_ftype == .directory) return Error.Unsupported;
    }

    // A directory cannot be moved into itself or one of its own descendants.
    if (src_ftype == .directory and isAncestorOrSelf(old_path.dentry, new_cur.dentry)) {
        return Error.InvalidArgument;
    }

    // Do the actual rename operation on the filesystem.
    try old_cur.dentry.inode.rename(
        old_name,
        old_path.dentry.inode,
        new_cur.dentry.inode,
        new_name,
        if (dst_path) |d| d.dentry.inode else null,
    );

    // Remove the old and replaced dentry from the cache.
    // Keep the old dentry alive while it's inserted again to reuse it.
    old_path.dentry.ref();
    defer old_path.dentry.unref();
    dcache.remove(old_cur.dentry, old_name);

    if (dst_path != null) {
        dcache.remove(new_cur.dentry, new_name);
    }

    const name_copy = try old_path.dentry.allocator.dupe(u8, new_name);
    old_path.dentry.allocator.free(old_path.dentry.name);
    old_path.dentry.name = name_copy;
    old_path.dentry.parent = new_cur.dentry;

    try dcache.insert(old_path.dentry);
}

/// Move a directory entry to the specified directory with a new name.
///
/// If the new name already exists, it is replaced atomically.
pub fn rename(oldpath: []const u8, newpath: []const u8, allocator: Allocator) Error!void {
    const cur = sched.getCurrent();
    const old_basename = std.fs.path.basenamePosix(oldpath);
    const new_basename = std.fs.path.basenamePosix(newpath);
    if (old_basename.len == 0) return Error.InvalidArgument;
    if (new_basename.len == 0) return Error.InvalidArgument;

    const old_dir = if (std.fs.path.dirnamePosix(oldpath)) |dirname|
        try resolvePath(cur.fs.cwd, dirname, allocator)
    else
        cur.fs.cwd;
    const new_dir = if (std.fs.path.dirnamePosix(newpath)) |dirname|
        try resolvePath(cur.fs.cwd, dirname, allocator)
    else
        cur.fs.cwd;

    return renameAt(
        old_dir,
        old_basename,
        new_dir,
        new_basename,
        allocator,
    );
}

/// Check whether `self` is `candidate` itself or one of its ancestors.
fn isAncestorOrSelf(self: *Dentry, candidate: *Dentry) bool {
    var cur: ?*Dentry = candidate;
    while (cur) |d| : (cur = d.parent) {
        if (d == self) return true;
    } else return false;
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

/// Split the given path into its parent directory and final component.
fn resolveParent(base: Path, path: []const u8, allocator: Allocator) Error!struct { Path, []const u8 } {
    const basename = std.fs.path.basenamePosix(path);
    const parent = if (std.fs.path.dirnamePosix(path)) |dirname|
        try resolvePath(base, dirname, allocator)
    else
        base;

    return .{ parent, basename };
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
