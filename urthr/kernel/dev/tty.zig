//! TTY character device.
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

pub const name = "tty";

/// Per-TTY device state shared across all open file descriptors.
pub const Tty = struct {
    /// Foreground process group of this terminal.
    fg_pgid: u32 = 0,
};

/// Single TTY instance. All opens of /dev/tty share this state.
///
/// TODO: each TTY device should have its own instance.
var instance: Tty = .{};

fn open(_: *fs.Inode, _: Allocator) fs.Error!*anyopaque {
    instance.fg_pgid = urd.sched.getCurrent().group.getPgid();
    return @ptrCast(&instance);
}

fn write(_: *fs.File, buf: []const u8, _: usize) fs.Error!usize {
    urd.console.write(buf);
    return buf.len;
}

fn read(_: *fs.File, buf: []u8, _: usize) fs.Error!usize {
    return urd.input.read(buf);
}

fn ioctl(file: *fs.File, request: u64, arg: usize) fs.Error!usize {
    const tty = ctx(file);

    switch (@as(Request, @enumFromInt(request))) {
        .tcgets => {
            urd.uaccess.putUser(
                urd.input.Termios,
                arg,
                urd.input.getTermios(),
            ) catch return fs.Error.InvalidArgument;
        },
        .tcsets, .tcsetsw, .tcsetsf => {
            const t = urd.uaccess.getUser(
                urd.input.Termios,
                arg,
            ) catch return fs.Error.InvalidArgument;
            urd.input.setTermios(t);
        },
        .tiocgwinsz => {
            urd.uaccess.putUser(WinSize, arg, .{
                .row = 25,
                .col = 80,
                .xpixel = 0,
                .ypixel = 0,
            }) catch return fs.Error.InvalidArgument;
        },
        .tiocsctty => {
            // TODO
        },
        .tiocgpgrp => {
            urd.uaccess.putUser(
                u32,
                arg,
                tty.fg_pgid,
            ) catch return fs.Error.InvalidArgument;
        },
        .tiocspgrp => {
            tty.fg_pgid = urd.uaccess.getUser(
                u32,
                arg,
            ) catch return fs.Error.InvalidArgument;
        },
        else => return fs.Error.Unsupported,
    }
    return 0;
}

fn poll(_: *fs.File) fs.Error!fs.PollResult {
    return .{
        .events = .{
            .in = urd.input.available(),
            .out = true,
        },
        .wait = &urd.input.event,
    };
}

fn iterate(_: *fs.File.Iterator, _: Allocator) fs.Error!?fs.File.IterResult {
    return null;
}

fn close(_: *anyopaque, _: Allocator) void {}

inline fn ctx(file: *fs.File) *Tty {
    return @ptrCast(@alignCast(file.ctx));
}

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
    /// Make the given terminal the controlling terminal of the calling process.
    tiocsctty = 0x540E,
    /// Get the process group ID of the foreground process group of this terminal.
    tiocgpgrp = 0x540F,
    /// Set the foreground process group ID of this terminal.
    tiocspgrp = 0x5410,
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
