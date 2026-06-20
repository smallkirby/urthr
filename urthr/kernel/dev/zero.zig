//! zero character device.
//!
//! Implements `fs.File` interface.

pub const fops = fs.File.Ops{
    .open = open,
    .iterate = iterate,
    .read = read,
    .write = write,
    .close = close,
    .poll = poll,
};

pub const name = "zero";

fn open(_: *fs.Inode, _: Allocator) fs.Error!*anyopaque {
    return &.{};
}

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

fn poll(_: *fs.File) fs.Error!fs.PollResult {
    return .{ .events = .{
        .in = true,
        .out = true,
    } };
}

fn close(_: *anyopaque, _: Allocator) void {}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const urd = @import("urthr");
const fs = urd.fs;
