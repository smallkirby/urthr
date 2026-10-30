//! Input event character device (/dev/input/eventN).
//!
//! Implements `fs.File` interface.

pub const fops = fs.File.Ops{
    .open = open,
    .iterate = iterate,
    .read = read,
    .close = close,
    .poll = poll,
};

/// Event read from the device, compatible with Linux evdev.
const InputEvent = extern struct {
    /// Time when the event was reported.
    time: urd.posix.Timeval,
    /// Type of the event.
    type: EventType,
    /// Code of the event.
    code: u16,
    /// Value of the event.
    value: i32,

    comptime {
        std.debug.assert(@sizeOf(InputEvent) == 24);
    }
};

fn open(inode: *fs.Inode, allocator: Allocator) fs.Error!*anyopaque {
    const node: *Evdev = @ptrCast(@alignCast(
        fs.DevFs.InodeImpl.from(inode).ctx orelse return fs.Error.InvalidArgument,
    ));

    return try node.open(allocator);
}

fn read(file: *fs.File, buf: []u8, _: usize) fs.Error!usize {
    const size = @sizeOf(InputEvent);
    if (buf.len < size) return fs.Error.InvalidArgument;

    var records: [urd.input.evdev.queue_size]Record = undefined;
    const max = @min(buf.len / size, records.len);
    const n = try ctx(file).read(records[0..max], file.status_flags.nonblock);

    for (records[0..n], 0..) |record, i| {
        const event = InputEvent{
            .time = .fromNs(record.time_ns),
            .type = record.type,
            .code = record.code,
            .value = record.value,
        };
        @memcpy(buf[i * size ..][0..size], std.mem.asBytes(&event));
    }

    return n * size;
}

fn iterate(_: *fs.File.Iterator, _: Allocator) fs.Error!?fs.File.IterResult {
    return null;
}

fn close(file_ctx: *anyopaque, allocator: Allocator) void {
    const client: *Client = @ptrCast(@alignCast(file_ctx));
    client.close(allocator);
}

fn poll(file: *fs.File) fs.Error!fs.PollResult {
    const client = ctx(file);
    return .{
        .events = .{ .in = client.isReadable() },
        .wait = &client.event,
    };
}

inline fn ctx(file: *fs.File) *Client {
    return @ptrCast(@alignCast(file.ctx));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const EventType = common.input_codes.EventType;
const urd = @import("urthr");
const fs = urd.fs;
const evdev = urd.input.evdev;
const Evdev = evdev.Evdev;
const Client = evdev.Client;
const Record = evdev.Record;
