//! Console character device.
//!
//! Implements `fs.File` interface.

pub const fops = fs.File.Ops{
    .open = open,
    .iterate = iterate,
    .read = read,
    .write = write,
    .ioctl = ioctl,
    .close = close,
    .poll = poll,
};

pub const name = "console";

fn open(_: *fs.Inode, _: Allocator) fs.Error!*anyopaque {
    return &.{};
}

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

fn ioctl(_: *fs.File, request: u64, arg: usize) fs.Error!usize {
    switch (@as(Request, @enumFromInt(request))) {
        .tcgets => {
            const ret: *urd.input.Termios = @ptrFromInt(arg);
            ret.* = urd.input.getTermios();
        },
        .tcsets, .tcsetsw, .tcsetsf => {
            const t: *const urd.input.Termios = @ptrFromInt(arg);
            urd.input.setTermios(t.*);
        },
        .tiocgwinsz => {
            const ret: *WinSize = @ptrFromInt(arg);
            ret.* = .{
                .row = 25,
                .col = 80,
                .xpixel = 0,
                .ypixel = 0,
            };
        },
        else => return fs.Error.Unsupported,
    }
    return 0;
}

fn poll(_: *fs.File) fs.Error!fs.PollResult {
    return .{ .events = .{
        .out = true,
    } };
}

fn close(_: *anyopaque, _: Allocator) void {}

const WinSize = extern struct {
    row: u16,
    col: u16,
    xpixel: u16,
    ypixel: u16,
};

const Request = enum(u64) {
    /// Get the current serial port settings.
    tcgets = 0x5401,
    /// Set the serial port settings.
    tcsets = 0x5402,
    /// Allow the output buffer to drain, and set the current serial port settings.
    tcsetsw = 0x5403,
    /// Allow the output buffers to drain, discard pending input, and set the current serial port settings.
    tcsetsf = 0x5404,
    /// Get window size.
    tiocgwinsz = 0x5413,

    _,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const urd = @import("urthr");
const fs = urd.fs;
