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
    /// Too many symbolic links were encountered while resolving a path.
    Loop,
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

/// Location in the filesystem tree.
///
/// A function that returns a `Path` transfers its reference to the caller.
/// The caller must `put()` it after use.
///
/// A function that takes a `Path` only borrows it,
/// and takes its own reference only if it keeps the path.
///
/// Note that some functions may take over the reference to the path and consume it.
pub const Path = struct {
    /// Directory entry.
    dentry: *Dentry,
    // Mount this path belongs to.
    mount: ?*Mount,

    /// Take an additional reference to the path.
    pub fn get(self: Path) Path {
        self.dentry.ref();
        return self;
    }

    /// Release the reference held by the path.
    pub fn put(self: Path) void {
        self.dentry.unref();
    }
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
    dentry.* = .{
        .name = "",
        .inode = inode,
        .parent = null,
        .allocator = allocator,
    };
    dentry.ref(); // + for the cwd

    const current = sched.getCurrent();
    current.fs = .{
        .info = try .new(
            allocator,
            .{ .dentry = dentry, .mount = null },
            .{ .dentry = dentry, .mount = null },
        ),
        .fdtbl = try .new(allocator),
    };

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

    // Create a new dentry for the root of the mounted filesystem.
    // The dentry takes over the inode reference only on success.
    fs.root.ref();
    const root = Dentry.create("", fs.root, null, allocator) catch |err| {
        fs.root.unref();
        return err;
    };
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
    path.dentry.ref(); // + for the mount point
    path.dentry.mount = mnt;
}

/// Create a directory under the given directory with the given name.
pub fn mkdirAt(dir: Path, path: []const u8, mode: FileMode, allocator: Allocator) Error!void {
    glock.lock();
    defer glock.unlock();

    const parent, const basename = try resolveParent(
        dir,
        path,
        allocator,
    );
    const cur = followDown(parent);
    defer cur.put();

    if (basename.len == 0) {
        return Error.AlreadyExists;
    }
    if (std.mem.eql(u8, ".", basename) or std.mem.eql(u8, "..", basename)) {
        return Error.AlreadyExists;
    }

    const inode = try cur.dentry.inode.mkdir(
        basename,
        mode,
        allocator,
    );

    const dentry = try insertDentry(cur, basename, inode, allocator);
    dentry.unref();
}

/// Create a directory at the specified path.
pub fn mkdir(s: []const u8, mode: FileMode, allocator: Allocator) Error!void {
    const cwd = getCwd();
    defer cwd.put();

    return mkdirAt(
        cwd,
        s,
        mode,
        allocator,
    );
}

/// Create a symbolic link under the given directory with the given name pointing to `target`.
pub fn symlinkAt(dir: Path, linkpath: []const u8, target: []const u8, allocator: Allocator) Error!void {
    glock.lock();
    defer glock.unlock();

    const parent, const basename = try resolveParent(
        dir,
        linkpath,
        allocator,
    );
    const cur = followDown(parent);
    defer cur.put();

    if (basename.len == 0) {
        return Error.AlreadyExists;
    }
    if (std.mem.eql(u8, ".", basename) or std.mem.eql(u8, "..", basename)) {
        return Error.AlreadyExists;
    }

    const inode = try cur.dentry.inode.symlink(
        basename,
        target,
        allocator,
    );

    const dentry = try insertDentry(cur, basename, inode, allocator);
    dentry.unref();
}

/// Create a symbolic link pointing to `target` at the specified path.
pub fn symlink(target: []const u8, linkpath: []const u8, allocator: Allocator) Error!void {
    const cwd = getCwd();
    defer cwd.put();

    return symlinkAt(
        cwd,
        linkpath,
        target,
        allocator,
    );
}

/// Create a new regular file under the specified directory and open it.
pub fn createAt(dir: Path, path: []const u8, mode: FileMode, access: File.AccessMode, allocator: Allocator) Error!*File {
    glock.lock();
    defer glock.unlock();

    const parent, const basename = try resolveParent(
        dir,
        path,
        allocator,
    );
    const cur = followDown(parent);
    defer cur.put();

    if (basename.len == 0) {
        return Error.InvalidArgument;
    }
    if (std.mem.eql(u8, ".", basename) or std.mem.eql(u8, "..", basename)) {
        return Error.AlreadyExists;
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

    const dentry = try insertDentry(cur, basename, inode, allocator);
    defer dentry.unref();

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
    const cwd = getCwd();
    defer cwd.put();

    return createAt(
        cwd,
        s,
        mode,
        access,
        allocator,
    );
}

/// Resolve a path to a Path without opening a File.
///
/// If `follow` is true and the final component is a symbolic link, it is followed.
///
/// Caller must call `path.put()` after use.
pub fn resolve(s: []const u8, allocator: Allocator, follow: bool) Error!Path {
    const cwd = getCwd();
    defer cwd.put();

    return resolvePath(cwd, s, allocator, follow);
}

/// Read the target of a symbolic link at the specified path into the buffer.
///
/// If the buffer is too small, the content is implicitly truncated.
///
/// Returns the number of bytes written to the buffer.
pub fn readlink(s: []const u8, buf: []u8, allocator: Allocator) Error!usize {
    const path = try resolve(s, allocator, false);
    defer path.put();

    return path.dentry.inode.readlink(buf);
}

/// Read the target of a symbolic link relative to the given directory into the buffer.
///
/// If the buffer is too small, the content is implicitly truncated.
///
/// Returns the number of bytes written to the buffer.
pub fn readlinkAt(dir: Path, s: []const u8, buf: []u8, allocator: Allocator) Error!usize {
    if (std.fs.path.isAbsolute(s)) {
        return Error.InvalidArgument;
    }
    if (dir.dentry.inode.ftype != .directory) {
        return Error.NotDirectory;
    }

    const path = try resolvePath(dir, s, allocator, false);
    defer path.put();

    return path.dentry.inode.readlink(buf);
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
///
/// If `follow` is true and the final component is a symbolic link, it is followed.
pub fn open(s: []const u8, access: File.AccessMode, allocator: Allocator, follow: bool) Error!*File {
    const path = try resolve(s, allocator, follow);
    defer path.put();

    return File.open(path, access, allocator);
}

/// Open a file relative to a directory.
///
/// If `follow` is true and the final component is a symbolic link, it is followed.
pub fn openAt(dir: Path, s: []const u8, access: File.AccessMode, allocator: Allocator, follow: bool) Error!*File {
    if (std.fs.path.isAbsolute(s)) {
        return Error.InvalidArgument;
    }
    if (dir.dentry.inode.ftype != .directory) {
        return Error.NotDirectory;
    }

    const path = try resolvePath(dir, s, allocator, follow);
    defer path.put();

    return File.open(path, access, allocator);
}

/// Remove a regular file at the specified path.
///
/// The directory entry is removed immediately,
/// but the underlying storage is only reclaimed once the last open file referring to it is closed.
pub fn unlink(s: []const u8, allocator: Allocator) Error!void {
    glock.lock();
    defer glock.unlock();

    const path = try resolve(s, allocator, false);
    defer path.put();

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

    glock.lock();
    defer glock.unlock();

    const path = try resolvePath(dir, s, allocator, false);
    defer path.put();

    return unlinkImpl(path, s);
}

/// Detach the directory entry.
fn unlinkImpl(path: Path, s: []const u8) Error!void {
    if (path.dentry.inode.ftype == .directory) {
        return Error.NotFile;
    }

    // A regular file always has a parent.
    const parent_dentry = path.dentry.parent.?;
    const basename = std.fs.path.basenamePosix(s);

    try parent_dentry.inode.unlink(path.dentry.inode);
    dcache.remove(parent_dentry, basename, isCaseInsensitive(path.mount));
}

/// Remove an empty directory at the specified path.
pub fn rmdir(s: []const u8, allocator: Allocator) Error!void {
    glock.lock();
    defer glock.unlock();

    const path = try resolve(s, allocator, false);
    defer path.put();

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

    glock.lock();
    defer glock.unlock();

    const path = try resolvePath(dir, s, allocator, false);
    defer path.put();

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
    dcache.remove(parent_dentry, basename, isCaseInsensitive(path.mount));
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
/// If the new name already exists and `noreplace` is not set, it is replaced atomically.
pub fn renameAt(old_dir: Path, old_name: []const u8, new_dir: Path, new_name: []const u8, noreplace: bool, allocator: Allocator) Error!void {
    glock.lock();
    defer glock.unlock();

    const old_parent, const old_basename = try resolveParent(
        old_dir,
        old_name,
        allocator,
    );
    const old_cur = followDown(old_parent);
    defer old_cur.put();

    const new_parent, const new_basename = try resolveParent(
        new_dir,
        new_name,
        allocator,
    );
    const new_cur = followDown(new_parent);
    defer new_cur.put();

    if (old_basename.len == 0 or new_basename.len == 0 or
        std.mem.eql(u8, ".", old_basename) or std.mem.eql(u8, "..", old_basename) or
        std.mem.eql(u8, ".", new_basename) or std.mem.eql(u8, "..", new_basename))
    {
        return Error.InvalidArgument;
    }

    if (old_cur.dentry.inode.ftype != .directory) return Error.NotDirectory;
    if (new_cur.dentry.inode.ftype != .directory) return Error.NotDirectory;
    if (old_cur.mount != new_cur.mount) return Error.CrossDevice;

    // The source must exist.
    const old_path = try resolvePath(
        old_cur,
        old_basename,
        allocator,
        false,
    );
    defer old_path.put();

    // Cannot rename mount points.
    if (old_path.dentry.parent == null) {
        return Error.Busy;
    }

    // The destination may or may not exist.
    const dst_path: ?Path = resolvePath(
        new_cur,
        new_basename,
        allocator,
        false,
    ) catch |err| switch (err) {
        Error.NotFound => null,
        else => return err,
    };
    defer if (dst_path) |d| d.put();

    // Renaming an entry onto itself is a no-op.
    if (dst_path) |d| {
        if (d.dentry == old_path.dentry) return;
    }
    if (noreplace and dst_path != null) {
        return Error.AlreadyExists;
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
        old_basename,
        old_path.dentry.inode,
        new_cur.dentry.inode,
        new_basename,
        if (dst_path) |d| d.dentry.inode else null,
    );

    // Remove the old and replaced dentry from the cache.
    dcache.remove(old_cur.dentry, old_basename, isCaseInsensitive(old_cur.mount));

    if (dst_path != null) {
        dcache.remove(new_cur.dentry, new_basename, isCaseInsensitive(new_cur.mount));
    }

    const name_copy = try old_path.dentry.allocator.dupe(u8, new_basename);
    old_path.dentry.allocator.free(old_path.dentry.name);
    old_path.dentry.name = name_copy;
    new_cur.dentry.ref();
    const prev_parent = old_path.dentry.parent;
    old_path.dentry.parent = new_cur.dentry;
    if (prev_parent) |p| p.unref();

    dcache.insert(old_path.dentry, isCaseInsensitive(new_cur.mount)).unref();
}

/// Move a directory entry to the specified directory with a new name.
///
/// If the new name already exists, it is replaced atomically.
pub fn rename(oldpath: []const u8, newpath: []const u8, allocator: Allocator) Error!void {
    const old_basename = std.fs.path.basenamePosix(oldpath);
    const new_basename = std.fs.path.basenamePosix(newpath);
    if (old_basename.len == 0) return Error.InvalidArgument;
    if (new_basename.len == 0) return Error.InvalidArgument;

    const old_dir = if (std.fs.path.dirnamePosix(oldpath)) |dirname|
        try resolve(dirname, allocator, true)
    else
        getCwd();
    defer old_dir.put();

    const new_dir = if (std.fs.path.dirnamePosix(newpath)) |dirname|
        try resolve(dirname, allocator, true)
    else
        getCwd();
    defer new_dir.put();

    return renameAt(
        old_dir,
        old_basename,
        new_dir,
        new_basename,
        false,
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

/// Upper bound on the number of symlinks followed while resolving a single path.
const max_symlink_depth = 40;

/// Resolve a file path to a `Path`.
///
/// Symbolic links in non-final components are always followed.
/// The final component is followed only if `follow` is true.
///
/// Caller must call `put()` for the returned path after use.
fn resolvePath(base: Path, s: []const u8, allocator: Allocator, follow: bool) Error!Path {
    return resolvePathImpl(base, s, allocator, follow, 0);
}

fn resolvePathImpl(base: Path, s: []const u8, allocator: Allocator, follow: bool, depth: usize) Error!Path {
    var cur: Path = if (std.fs.path.isAbsolutePosix(s))
        sched.getCurrent().fs.info.getRoot()
    else
        base.get();

    cur = followDown(cur);
    errdefer cur.put();

    var iter = ComponentIterator.init(s);
    while (iter.next()) |c| {
        if (std.mem.eql(u8, ".", c.name)) {
            continue;
        }

        if (std.mem.eql(u8, "..", c.name)) {
            cur = follow2dots(cur);
            continue;
        }

        // Check if the current dentry is a mount point.
        cur = followDown(cur);
        const ci = isCaseInsensitive(cur.mount);

        // Resolve this component.
        var next: Path = undefined;
        if (dcache.lookup(cur.dentry, c.name, ci)) |d| {
            next = .{ .dentry = d, .mount = cur.mount };
        } else {
            // Look up the child dentry.
            if (cur.dentry.inode.ftype != .directory) {
                return Error.NotDirectory;
            }
            const child = try cur.dentry.inode.lookup(c.name) orelse {
                return Error.NotFound;
            };

            // Create a new dentry and insert it into the cache.
            // If another thread has cached the same entry, use new one.
            const created = Dentry.create(
                c.name,
                child,
                cur.dentry,
                allocator,
            ) catch |err| {
                child.unref();
                return err;
            };
            defer created.unref();
            next = .{
                .dentry = dcache.insert(created, ci),
                .mount = cur.mount,
            };
        }

        // Follow a symlink.
        const is_last = iter.peekNext() == null;
        if (next.dentry.inode.ftype == .symlink and (!is_last or follow)) {
            defer next.put();
            const resolved = try followSymlink(
                cur,
                next.dentry,
                allocator,
                depth,
            );
            cur.put();
            cur = resolved;
            continue;
        }

        cur.put();
        cur = next;
    }

    return followDown(cur);
}

/// Step into the mount attached to the path if any.
///
/// Decrements the reference to `path` and returns a new path with reference.
/// nop if the path is not a mount point.
fn followDown(path: Path) Path {
    const mnt = path.dentry.mount orelse {
        return path;
    };
    const root = Path{
        .dentry = mnt.root,
        .mount = mnt,
    };

    // The mount root is kept alive only by `path`, so take a reference to it first.
    const ret = root.get();
    path.put();
    return ret;
}

/// Step up to the parent directory, crossing the mount boundary if needed.
///
/// nop if the path is the root of the root filesystem.
/// Decrements the reference to `path` and returns a new path with reference.
fn follow2dots(path: Path) Path {
    var parent = Path{
        .dentry = path.dentry.parent orelse path.dentry,
        .mount = path.mount,
    };
    if (path.mount) |mnt| {
        if (path.dentry == mnt.root) {
            const parent_mnt = mnt.parent orelse return path;
            parent = .{
                .dentry = mnt.mntpoint.parent orelse mnt.mntpoint,
                .mount = parent_mnt,
            };
        }
    }

    // The parent is kept alive only by `path`, so take a reference to it first.
    const ret = parent.get();
    path.put();
    return ret;
}

/// Get the current thread's working directory.
///
/// Caller must call `put()` for the returned path after use.
fn getCwd() Path {
    return sched.getCurrent().fs.info.getCwd();
}

/// Split the given path into its parent directory and final component.
///
/// Caller must call `put()` for the returned directory after use.
fn resolveParent(base: Path, path: []const u8, allocator: Allocator) Error!struct { Path, []const u8 } {
    const basename = std.fs.path.basenamePosix(path);
    const parent = if (std.fs.path.dirnamePosix(path)) |dirname|
        try resolvePath(base, dirname, allocator, true)
    else
        base.get();

    return .{ parent, basename };
}

/// Follow the symbolic link to its target.
fn followSymlink(dir: Path, link: *Dentry, allocator: Allocator, depth: usize) Error!Path {
    if (depth >= max_symlink_depth) {
        return Error.Loop;
    }

    const symlink_max_len = 4096;
    const buf = try allocator.alloc(u8, symlink_max_len);
    defer allocator.free(buf);
    const n = try link.inode.readlink(buf);

    return resolvePathImpl(
        dir,
        buf[0..n],
        allocator,
        true,
        depth + 1,
    );
}

/// Create a dentry for the newly created inode and put it into the dentry cache.
///
/// Takes over the caller's reference to the inode.
/// Returns the cached dentry with a new reference owned by the caller.
///
/// Inserted dentry holds two references.
/// One for the dentry cache, and one for the caller.
fn insertDentry(dir: Path, name: []const u8, inode: *Inode, allocator: Allocator) Error!*Dentry {
    const dentry = Dentry.create(
        name,
        inode,
        dir.dentry,
        allocator,
    ) catch |err| {
        inode.unref();
        return err;
    };
    defer dentry.unref();

    return dcache.insert(dentry, isCaseInsensitive(dir.mount));
}

/// Whether name lookups directly under the given mount should ignore case.
fn isCaseInsensitive(mnt: ?*Mount) bool {
    return if (mnt) |m| m.filesystem.case_insensitive else false;
}

// =============================================================
// Path resolution
// =============================================================

const ComponentIterator = std.fs.path.ComponentIterator(.posix, u8);

/// dentry cache instance.
var dcache: Dentry.Cache = undefined;
/// Serializes directory-namespace operations.
var glock: Mutex = .{};

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
const Mutex = urd.sync.Mutex;
