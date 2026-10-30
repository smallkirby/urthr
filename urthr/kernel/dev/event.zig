//! Input event character device (/dev/input/eventN).
//!
//! Implements `fs.File` interface.

/// Version of the evdev interface.
const evdev_version: i32 = 0x010001;

pub const fops = fs.File.Ops{
    .open = open,
    .iterate = iterate,
    .read = read,
    .close = close,
    .poll = poll,
    .ioctl = ioctl,
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

// =============================================================
// ioctl
// =============================================================

/// Identifier of the device.
const InputId = extern struct {
    /// Bus the device is connected to.
    bustype: Bus,
    /// Vendor ID.
    vendor: u16,
    /// Product ID.
    product: u16,
    /// Product version.
    version: u16,
};

/// Command number of ioctl request.
const Nr = enum(u8) {
    /// EVIOCGVERSION: Get the version of the evdev interface.
    version = 0x01,
    /// EVIOCGID: Get the identifier of the device.
    id = 0x02,
    /// EVIOCGNAME: Get the name of the device.
    name = 0x06,
    /// EVIOCGKEY: Get the state of the keys.
    key = 0x18,
    /// EVIOCGRAB: Grab or release the device.
    grab = 0x90,

    _,

    /// Number of the first request of EVIOCGBIT.
    const eviocgbit_start = 0x20;
    /// The number of event types distinguished by EVIOCGBIT.
    const eviocgbit_size = 0x20;

    /// Whether the command is EVIOCGBIT.
    pub fn isGetBits(self: Nr) bool {
        return @backingInt(self) >= eviocgbit_start and
            @backingInt(self) < eviocgbit_start + eviocgbit_size;
    }

    /// Get the requested event type for EVIOCGBIT.
    pub fn getRequestedEvent(self: Nr) u8 {
        rtt.expect(self.isGetBits());
        return @backingInt(self) - eviocgbit_start;
    }
};

/// ioctl request.
const Request = packed struct(u32) {
    /// Request number.
    nr: Nr,
    /// Type of the driver.
    type: Rtype,
    /// Size of the argument.
    size: u14,
    /// Direction of the data transfer.
    dir: Direction,

    const Direction = enum(u2) {
        none = 0,
        write = 1,
        read = 2,
        rw = 3,
    };

    const Rtype = enum(u8) {
        evdev = 'E',
        _,
    };

    pub fn from(request: u64) ?Request {
        return @bitCast(std.math.cast(u32, request) orelse return null);
    }
};

fn ioctl(file: *fs.File, request: u64, arg: usize) fs.Error!usize {
    const dev = ctx(file).evdev.dev;
    const req = Request.from(request) orelse return fs.Error.Unsupported;
    if (req.type != .evdev) return fs.Error.Unsupported;

    // EVIOCGBIT
    if (req.nr.isGetBits()) {
        return getBits(dev, req.nr.getRequestedEvent(), req.size, arg);
    }

    // Other requests.
    switch (req.nr) {
        .version => {
            urd.uaccess.putUser(i32, arg, evdev_version) catch return fs.Error.InvalidArgument;
            return 0;
        },

        .id => {
            urd.uaccess.putUser(InputId, arg, .{
                .bustype = dev.id.bustype,
                .vendor = dev.id.vendor,
                .product = dev.id.product,
                .version = dev.id.version,
            }) catch return fs.Error.InvalidArgument;
            return 0;
        },

        .name => {
            return getName(dev, req.size, arg);
        },

        .key => {
            const keys = dev.getKeys();
            return copyBytes(arg, req.size, std.mem.asBytes(&keys));
        },

        .grab => {
            const client = ctx(file);
            if (arg != 0) {
                try client.evdev.grab(client);
            } else {
                try client.evdev.ungrab(client);
            }
            return 0;
        },

        _ => {
            return fs.Error.Unsupported;
        },
    }
}

/// Copy the name of the device including the null terminator.
///
/// Returns the number of bytes copied.
fn getName(dev: *Device, len: usize, uout: usize) fs.Error!usize {
    const name = dev.name;
    const total = @min(len, name.len + 1); // +1 for terminator
    const text = @min(total, name.len);

    // Copy name string without terminator.
    _ = try copyBytes(uout, text, name);
    // Put a null-terminator.
    if (total > text) _ = try copyBytes(uout + text, 1, &.{0});

    return total;
}

/// Copy the bitmap of the supported codes of the event type.
///
/// Returns the number of bytes copied.
fn getBits(dev: *Device, ev: usize, len: usize, arg: usize) fs.Error!usize {
    // Bitmap of the event types.
    if (ev == @backingInt(EventType.syn)) {
        var types: u32 = 1 << @backingInt(EventType.syn);
        if (dev.keybit.count() != 0) types |= 1 << @backingInt(EventType.key);
        return copyBytes(arg, len, std.mem.asBytes(&types));
    }

    // Bitmap of the key codes.
    if (ev == @backingInt(EventType.key)) {
        return copyBytes(arg, len, std.mem.asBytes(&dev.keybit));
    }

    // The device does not support other event types.
    const empty: [@sizeOf(usize)]u8 = @splat(0);
    return copyBytes(arg, len, &empty);
}

// =============================================================
// Helpers
// =============================================================

inline fn ctx(file: *fs.File) *Client {
    return @ptrCast(@alignCast(file.ctx));
}

/// Copy up to `len` bytes of the data to the user buffer.
///
/// Returns the number of bytes copied.
fn copyBytes(uaddr: usize, len: usize, data: []const u8) fs.Error!usize {
    const n = @min(len, data.len);
    urd.uaccess.copyToUser(uaddr, data[0..n]) catch return fs.Error.InvalidArgument;

    return n;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const rtt = common.rtt;
const EventType = common.input_codes.EventType;
const urd = @import("urthr");
const fs = urd.fs;
const Device = urd.input.Device;
const Bus = Device.Bus;
const evdev = urd.input.evdev;
const Evdev = evdev.Evdev;
const Client = evdev.Client;
const Record = evdev.Record;
