//! Filesystem interface.
//!
//! This provides a common interface for different filesystem implementations.

const Self = @This();
const FileSystem = Self;
const Error = fs.Error;

/// Type-erased pointer to the filesystem implementation.
ptr: *anyopaque,
/// Vtable for the filesystem interface.
vtable: *const Vtable,

/// Root directory.
root: *Inode,

pub const Vtable = struct {};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const urd = @import("urthr");
const fs = urd.fs;
const Inode = fs.Inode;
