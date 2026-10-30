//! Event device handler.
//!
//! Exposes input devices as an event node /dev/input/eventN.

/// The number of events a client can queue.
pub const queue_size = 64;

/// Event stored in the queue of clients.
pub const Record = struct {
    /// Time when the event was reported in nanoseconds.
    time_ns: u64,
    /// Type of the event.
    type: EventType,
    /// Code of the event.
    code: u16,
    /// Value of the event.
    value: i32,
};

/// Event node of an input device.
pub const Evdev = struct {
    /// Input device this node exposes.
    dev: *Device,
    /// Lock protecting the list of clients and their queues.
    lock: SpinLock = .{},
    /// Clients that have opened this node.
    clients: Client.List = .{},

    /// Create a client of this node.
    pub fn open(self: *Evdev, allocator: Allocator) Allocator.Error!*Client {
        const client = try allocator.create(Client);
        client.* = .{ .evdev = self };

        const ie = self.lock.lockDisableIrq();
        defer self.lock.unlockRestoreIrq(ie);
        self.clients.append(client);

        return client;
    }

    /// Grab the device for the client.
    ///
    /// While the device is grabbed, only the client receives the events.
    pub fn grab(self: *Evdev, client: *Client) fs.Error!void {
        try self.dev.grab(&handler, client);
    }

    /// Release the grab of the client.
    pub fn ungrab(self: *Evdev, client: *Client) fs.Error!void {
        try self.dev.ungrab(&handler, client);
    }

    /// Queue the event to all clients.
    ///
    /// If the device is grabbed, only the grabbing client receives the event.
    fn push(self: *Evdev, record: Record) void {
        rtt.expect(self.dev.lock.isLocked());

        const ie = self.lock.lockDisableIrq();
        defer self.lock.unlockRestoreIrq(ie);

        if (self.dev.grabber) |grabber| {
            const client: *Client = @ptrCast(@alignCast(grabber.owner));
            return client.push(record);
        }

        var iter = self.clients.iter();
        while (iter.next()) |client| {
            client.push(record);
        }
    }
};

/// Opener of an event node.
pub const Client = struct {
    /// Node this client belongs to.
    evdev: *Evdev,
    /// List head.
    list_head: List.Head = .{},

    /// Queue of events.
    queue: [queue_size]Record = undefined,
    /// Read position.
    head: usize = 0,
    /// Position of the end of the last complete packet.
    packet_head: usize = 0,
    /// Write position.
    tail: usize = 0,

    /// Condition variable for the reader waiting for events.
    cv: CondVar = .{},
    /// Event signaled when events become readable.
    event: Event = .{},

    const List = InlineDoublyLinkedList(Client, "list_head");

    /// Destroy the client.
    pub fn close(self: *Client, allocator: Allocator) void {
        self.evdev.ungrab(self) catch {};

        {
            const ie = self.evdev.lock.lockDisableIrq();
            defer self.evdev.lock.unlockRestoreIrq(ie);
            self.evdev.clients.remove(self);
        }

        allocator.destroy(self);
    }

    /// Read events into the buffer, waiting until at least one event is readable.
    ///
    /// Returns the number of events read.
    pub fn read(self: *Client, out: []Record, nonblock: bool) fs.Error!usize {
        const ie = self.evdev.lock.lockDisableIrq();
        defer self.evdev.lock.unlockRestoreIrq(ie);

        while (self.head == self.packet_head) {
            if (nonblock) return fs.Error.WouldBlock;
            self.cv.wait(&self.evdev.lock);
        }

        var n: usize = 0;
        while (n < out.len and self.head != self.packet_head) : (n += 1) {
            out[n] = self.queue[self.head % queue_size];
            self.head += 1;
        }

        return n;
    }

    /// Check if there are events that can be read without blocking.
    pub fn isReadable(self: *Client) bool {
        const ie = self.evdev.lock.lockDisableIrq();
        defer self.evdev.lock.unlockRestoreIrq(ie);

        return self.head != self.packet_head;
    }

    /// Queue the event.
    ///
    /// The event becomes readable when the packet is completed.
    fn push(self: *Client, record: Record) void {
        rtt.expect(self.evdev.lock.isLocked());

        // If the queue is full, drop all the events and tell it to the client.
        if (self.tail - self.head == queue_size) {
            self.head = self.tail;
            self.enqueue(.{
                .time_ns = record.time_ns,
                .type = .syn,
                .code = @backingInt(Syn.dropped),
                .value = 0,
            });
            self.completePacket();
        }

        self.enqueue(record);
        if (record.type == .syn and record.code == @backingInt(Syn.report)) {
            self.completePacket();
        }
    }

    /// Enqueue the record into the ring buffer.
    fn enqueue(self: *Client, record: Record) void {
        self.queue[self.tail % queue_size] = record;
        self.tail += 1;
    }

    /// Make the queued events readable and notify the readers.
    fn completePacket(self: *Client) void {
        self.packet_head = self.tail;
        self.cv.signal();
        self.event.wakeAll();
    }
};

// =============================================================
// Event nodes
// =============================================================

/// The number of devices that can be exposed.
const max_evdevs = 8;

/// Event nodes.
var evdevs: [max_evdevs]Evdev = undefined;
/// The number of event nodes.
var evcount: std.atomic.Value(usize) = .init(0);
/// Lock to serialize creations of event nodes.
var lock: SpinLock = .{};

/// Find the event node of the device.
fn find(dev: *Device) ?*Evdev {
    for (evdevs[0..evcount.load(.acquire)]) |*evdev| {
        if (evdev.dev == dev) return evdev;
    } else return null;
}

// =============================================================
// Handler
// =============================================================

/// Input handler vtable.
pub const handler = Handler{
    .onKey = onKey,
    .onSync = onSync,
    .connect = connect,
};

/// Push the reported key event.
fn onKey(dev: *Device, key: Key, state: Device.KeyState) void {
    const evdev = find(dev) orelse return;
    evdev.push(.{
        .time_ns = urd.time.getRealtime(),
        .type = .key,
        .code = @backingInt(key),
        .value = @backingInt(state),
    });
}

/// Push the end-of-events marker.
fn onSync(dev: *Device) void {
    const evdev = find(dev) orelse return;
    evdev.push(.{
        .time_ns = urd.time.getRealtime(),
        .type = .syn,
        .code = @backingInt(Syn.report),
        .value = 0,
    });
}

/// Expose the newly registered device as /dev/input/eventN.
fn connect(dev: *Device) fs.Error!void {
    const index = blk: {
        const ie = lock.lockDisableIrq();
        defer lock.unlockRestoreIrq(ie);

        const n = evcount.load(.monotonic);
        if (n == max_evdevs) return fs.Error.NoSpace;

        evdevs[n] = .{ .dev = dev };
        evcount.store(n + 1, .release);

        break :blk n;
    };

    var buf: [16]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "input/event{d}", .{index}) catch unreachable;
    try urd.dev.register(path, devev.fops, &evdevs[index]);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const rtt = common.rtt;
const InlineDoublyLinkedList = common.typing.InlineDoublyLinkedList;
const input_codes = common.input_codes;
const EventType = input_codes.EventType;
const Key = input_codes.Key;
const Syn = input_codes.Syn;
const urd = @import("urthr");
const fs = urd.fs;
const sync = urd.sync;
const CondVar = sync.CondVar;
const Event = sync.Event;
const SpinLock = sync.SpinLock;

const Device = @import("Device.zig");
const Handler = @import("Handler.zig");
const devev = @import("../dev/event.zig");
