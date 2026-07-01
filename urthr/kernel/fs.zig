pub const FileSystem = @import("fs/FileSystem.zig");
pub const Inode = @import("fs/Inode.zig");
pub const Dentry = @import("fs/Dentry.zig");
pub const File = @import("fs/File.zig");
pub const Mount = @import("fs/Mount.zig");

pub const Fat32 = @import("fs/Fat32.zig");
pub const RootFs = @import("fs/RootFs.zig");
pub const DevFs = @import("fs/DevFs.zig");
pub const PipeFs = @import("fs/PipeFs.zig");
pub const ProcFs = @import("fs/ProcFs.zig");
pub const FdTable = @import("fs/FdTable.zig");

/// Filesystem-specific errors.
pub const Error = error{
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
} || block.Error;

pub const max_fds: usize = FdTable.max_fds;

/// File type.
pub const FileType = enum {
    /// Regular file.
    regular,
    /// Directory.
    directory,
};

pub const Path = struct {
    /// Directory entry.
    dentry: *Dentry,
    // Mount this path belongs to.
    mount: ?*Mount,
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

    // Initialize the dentry cache.
    dcache = Dentry.Cache.new(allocator);
    // Initialize the pipe filesystem.
    pipefs = try PipeFs.init(allocator);
}

/// Create a new pipe and return its read and write file objects.
pub fn createPipe() Error!PipeFs.PipePair {
    return pipefs.createPipe();
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

/// Create a directory at the given path with the given name.
pub fn mkdir(path: Path, name: []const u8, allocator: Allocator) Error!*Inode {
    var cur = path;
    if (cur.dentry.mount) |mnt| {
        cur = .{ .dentry = mnt.root, .mount = mnt };
    }

    return cur.dentry.inode.mkdir(name, allocator);
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
///
/// TODO: attributes and options.
pub fn open(s: []const u8, allocator: Allocator) Error!*File {
    const path = try resolvePath(sched.getCurrent().fs.cwd, s, allocator);
    return File.open(path, allocator);
}

/// Open a file relative to a directory.
///
/// TODO: attributes and options.
pub fn openAt(dir: Path, s: []const u8, allocator: Allocator) Error!*File {
    if (std.fs.path.isAbsolute(s)) {
        return Error.InvalidArgument;
    }
    if (dir.dentry.inode.ftype != .directory) {
        return Error.NotDirectory;
    }

    const path = try resolvePath(dir, s, allocator);
    return File.open(path, allocator);
}

/// Resolve a file path to a `Path`.
fn resolvePath(base: Path, s: []const u8, allocator: Allocator) Error!Path {
    var cur: Path = if (std.fs.path.isAbsolutePosix(s))
        sched.getCurrent().fs.root
    else
        base;

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
                        cur = .{ .dentry = parent_dentry, .mount = parent_mnt };
                    } else {
                        // Reached the root of root filesystem. Stay here.
                    }
                    continue;
                }
            }

            cur = .{
                .dentry = cur.dentry.parent orelse cur.dentry,
                .mount = cur.mount,
            };
            continue;
        }

        // Check if the current dentry is a mount point.
        if (cur.dentry.mount) |mnt| {
            cur = .{ .dentry = mnt.root, .mount = mnt };
        }

        // Check dcache first.
        if (dcache.lookup(cur.dentry, c.name)) |d| {
            cur = .{ .dentry = d, .mount = cur.mount };
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

        cur = .{ .dentry = dentry, .mount = cur.mount };
    }

    // Handle the case where the final path component is itself a mount point.
    if (cur.dentry.mount) |mnt| {
        cur = .{ .dentry = mnt.root, .mount = mnt };
    }

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
