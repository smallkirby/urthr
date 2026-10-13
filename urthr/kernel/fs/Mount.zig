//! Mount information.
//!
//! This struct represents a mounted filesystem and its associated information.

const Self = @This();
const Mount = Self;
const Error = fs.Error;

/// Filesystem this mount belongs to.
filesystem: FileSystem,
/// Root dentry of the mounted tree.
root: *Dentry,
/// Parent mount.
///
/// null if this mount is the root mount.
parent: ?*Mount,
/// Dentry of a directory to which this mount is attached.
mntpoint: *Dentry,

/// List of mounts in the system.
pub const Table = struct {
    /// Protects the attachment of mounts to mount point dentries.
    lock: SharedLock = .{},

    /// Mount a filesystem to the specified path.
    pub fn attach(self: *Table, path: Path, filesystem: FileSystem, allocator: Allocator) Error!void {
        self.lock.lock(.exclusive);
        defer self.lock.unlock(.exclusive);

        if (path.dentry.getInode().ftype != .directory) {
            return Error.NotDirectory;
        }
        if (path.dentry.mount != null) {
            return Error.AlreadyMounted;
        }

        // Create a new dentry for the root of the mounted filesystem.
        // The dentry takes over the inode reference only on success.
        filesystem.root.ref();
        const root = Dentry.create("", filesystem.root, null, allocator) catch |err| {
            filesystem.root.unref();
            return err;
        };
        errdefer root.unref();

        // Attach the new mount to the mount point.
        const mnt = try allocator.create(Mount);
        errdefer allocator.destroy(mnt);
        mnt.* = .{
            .filesystem = filesystem,
            .root = root,
            .parent = path.mount,
            .mntpoint = path.dentry,
        };
        path.dentry.ref(); // + for the mount point
        path.dentry.mount = mnt;
    }

    /// Detach the mount from its mount point.
    ///
    /// The caller must hold a reference to the root of the mount.
    pub fn detach(self: *Table, mnt: *Mount, allocator: Allocator) Error!void {
        self.lock.lock(.exclusive);
        defer self.lock.unlock(.exclusive);

        // The mount itself and the caller must be the only references.
        if (mnt.root.refcnt.load(.acquire) != 2) {
            return Error.Busy;
        }

        mnt.mntpoint.mount = null;
        mnt.mntpoint.unref();
        mnt.root.unref();
        allocator.destroy(mnt);
    }

    /// Step into the mount attached to the path if any.
    ///
    /// Decrements the reference to `path` and returns a new path with reference.
    /// nop if the path is not a mount point.
    pub fn followDown(self: *Table, path: Path) Path {
        self.lock.lock(.shared);
        const mnt = path.dentry.mount orelse {
            self.lock.unlock(.shared);
            return path;
        };
        const root = Path{
            .dentry = mnt.root,
            .mount = mnt,
        };
        const ret = root.get();
        self.lock.unlock(.shared);

        path.put();
        return ret;
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const urd = @import("urthr");
const fs = urd.fs;
const Path = fs.Path;
const SharedLock = urd.sync.SharedLock;
const FileSystem = @import("FileSystem.zig");
const Dentry = @import("Dentry.zig");
