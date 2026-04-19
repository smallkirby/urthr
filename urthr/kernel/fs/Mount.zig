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

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const urd = @import("urthr");
const fs = urd.fs;
const FileSystem = @import("FileSystem.zig");
const Dentry = @import("Dentry.zig");
