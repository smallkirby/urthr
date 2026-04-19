pub const FileSystem = @import("fs/FileSystem.zig");
pub const Inode = @import("fs/Inode.zig");
pub const Dentry = @import("fs/Dentry.zig");
pub const File = @import("fs/File.zig");
pub const Mount = @import("fs/Mount.zig");

pub const Fat32 = @import("fs/Fat32.zig");

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
} || block.Error;

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

/// Open a file at the specified path.
///
/// TODO: attributes and options.
pub fn open(s: []const u8, allocator: Allocator) Error!*File {
    var cur: Path = if (std.fs.path.isAbsolutePosix(s))
        sched.getCurrent().fs.root
    else
        sched.getCurrent().fs.cwd;

    if (cur.dentry.mount) |mnt| {
        cur = .{ .dentry = mnt.root, .mount = mnt };
    }

    var iter = ComponentIterator.init(s) catch unreachable;
    while (iter.next()) |c| {
        if (std.mem.eql(u8, ".", c.name)) continue;
        if (std.mem.eql(u8, "..", c.name)) urd.unimplemented("fs.open: ..");

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

    return try File.open(cur, allocator);
}

// =============================================================
// Path resolution
// =============================================================

const ComponentIterator = std.fs.path.ComponentIterator(.posix, u8);

/// dentry cache instance.
var dcache: Dentry.Cache = undefined;

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
