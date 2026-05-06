//! Console character device.
//!
//! Implements `fs.File` interface.

pub const file_ops = fs.File.Ops{
    .iterate = iterate,
    .read = read,
    .write = write,
    .close = close,
};

fn write(_: *fs.File, buf: []const u8, _: usize) fs.Error!usize {
    urd.console.write(buf);

    return buf.len;
}

fn read(_: *fs.File, _: []u8, _: usize) fs.Error!usize {
    return fs.Error.Unsupported;
}

fn iterate(_: *fs.File.Iterator, _: Allocator) fs.Error!?fs.File.IterResult {
    return null;
}

fn close(_: *anyopaque, _: Allocator) void {}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const urd = @import("urthr");
const fs = urd.fs;
