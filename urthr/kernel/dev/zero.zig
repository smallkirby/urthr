//! zero character device.
//!
//! Implements `fs.File` interface.

pub const fops = fs.File.Ops{
    .iterate = iterate,
    .read = read,
    .write = write,
    .close = close,
};

pub const name = "zero";

fn write(_: *fs.File, buf: []const u8, _: usize) fs.Error!usize {
    return buf.len;
}

fn read(_: *fs.File, buf: []u8, _: usize) fs.Error!usize {
    @memset(buf, 0);
    return buf.len;
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
