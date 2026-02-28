pub const arp = @import("net/arp.zig");
pub const ether = @import("net/ether.zig");
pub const ip = @import("net/ip.zig");

pub const Device = @import("net/Device.zig");
pub const Interface = @import("net/Interface.zig");
pub const Loopback = @import("net/Loopback.zig");

/// Registered network device list.
var device_list: Device.DeviceList = .{};

/// Packet queue for deferring RX processing.
var pktq: PacketQueue = .{};

/// Maximum number of packets to process per device in a single IRQ poll.
const poll_budget = 64;

/// Network error.
pub const Error = error{
    /// Given operation would cause duplication.
    Duplicated,
    /// Memory allocation failed.
    OutOfMemory,
    /// Invalid address.
    InvalidAddress,
    /// Invalid packet data.
    InvalidPacket,
    /// Given data, protocol, or operation is not supported.
    Unsupported,
    /// Operation timed out.
    Timeout,
};

/// Network protocols.
pub const Protocol = enum(u16) {
    /// IPv4
    ip = 0x0800,
    /// ARP
    arp = 0x0806,

    /// All other unrecognized protocols.
    _,

    /// Functions to handle the protocol data.
    pub const Vtable = struct {
        /// Process the incoming data.
        input: *const fn (dev: *const Device, data: []const u8) Error!void,
    };

    /// Get the handler for the given protocol.
    fn getHandler(self: Protocol) ?Protocol.Vtable {
        return switch (self) {
            .ip => @import("net/ip.zig").vtable,
            .arp => @import("net/arp.zig").vtable,
            else => null,
        };
    }
};

/// Initialize network subsystem.
pub fn init() void {}

/// Start running the network subsystem and register devices.
pub fn run() (Error || urd.sched.Error)!void {
    // Link-up all registered devices.
    var iter = device_list.iter();
    while (iter.next()) |device| {
        std.log.info("device @ {X}", .{@intFromPtr(device)});
        try device.open();
    }

    // Start the worker thread.
    _ = try urd.sched.spawn("net", worker, .{});
}

/// Register a network device.
pub fn registerDevice(device: *Device) void {
    device_list.append(device);
}

/// Handle incoming data to dispatch to the appropriate protocol handler.
pub fn handleInput(dev: *const Device, prot: Protocol, data: []const u8) Error!void {
    if (prot.getHandler()) |handler| {
        // Delegate to the protocol handler
        return handler.input(dev, data);
    } else {
        // Ignore unrecognized protocol
        return;
    }
}

/// Register IRQ vector for the given device.
pub fn registerIrq(dev: *Device, irq: urd.exception.Vector) Error!void {
    dev.irq = irq;

    urd.exception.setHandler(irq, handleIrq) catch {
        @panic("Failed to set IRQ handler for device");
    };
}

/// IRQ handler for all registered devices.
///
/// Iterates through the device list to find the device associated with the given IRQ.
fn handleIrq(irq: urd.exception.Vector) void {
    var iter = device_list.iter();
    while (iter.next()) |device| {
        if (device.irq == irq) {
            break pollDevice(device);
        }
    }
}

/// Poll a device for incoming packets and enqueue them.
///
/// Continuously polls the device until no more packets are available,
/// the packet queue is full, or the budget is exhausted.
fn pollDevice(device: *Device) void {
    var budget: usize = poll_budget;
    while (budget > 0) : (budget -= 1) {
        const result = device.poll() catch continue orelse break;
        pktq.enqueue(.{
            .data = result.data,
            .device = device,
            .handle = result.handle,
        }) catch |err| switch (err) {
            // If the queue is full, just drop the packet.
            error.Full => {},
        };
    }
}

/// Network worker thread function.
///
/// Continuously processes incoming packets from the packet queue
/// and dispatches them to the appropriate device handlers.
fn worker() void {
    while (true) {
        const pkt = pktq.dequeue();
        defer pktq.release(pkt);

        pkt.device.inputFrame(pkt.data);
    }
}

/// Get a reader that handles reading data represented in network byte order.
pub fn WireReader(T: type) type {
    return struct {
        const Self = @This();

        /// Pointer to the backing data.
        p: *const T,

        /// Fields enum type.
        const Fields = std.meta.FieldEnum(T);

        /// Create a new reader for the given object.
        pub fn new(obj: anytype) Self {
            const ptr: *const T = switch (@typeInfo(@TypeOf(obj))) {
                .pointer => |pointer| switch (pointer.size) {
                    .one, .many, .c => @ptrCast(@alignCast(obj)),
                    .slice => @ptrCast(@alignCast(obj.ptr)),
                },
                else => @compileError("Invalid type for WireReader"),
            };

            return Self{
                .p = ptr,
            };
        }

        /// Read the value of the given field.
        ///
        /// If the field is an extern struct, it is returned as-is.
        /// Otherwise, it is converted from big-endian to native endian.
        pub fn read(self: *const Self, comptime field: Fields) @FieldType(T, @tagName(field)) {
            const name = @tagName(field);
            const U = @FieldType(T, name);
            const bitoffset = @bitOffsetOf(T, name);
            const offset = @offsetOf(T, name);
            const bitsize = @bitSizeOf(U);

            if (bitsize % 8 != 0 or bitoffset % 8 != 0) {
                @compileError("Unsupported field alignment for WireReader");
            }

            const up = @intFromPtr(self.p) + offset;
            const value: *align(1) const U = @ptrFromInt(up);

            return switch (@typeInfo(U)) {
                .@"struct" => |s| if (s.layout == .@"extern")
                    value.*
                else
                    bits.fromBigEndian(value.*),
                else => bits.fromBigEndian(value.*),
            };
        }
    };
}

/// Convert the given value in network endian to native endian.
pub fn fromNetEndian(value: anytype) @TypeOf(value) {
    return bits.fromBigEndian(value);
}

/// Convert the given value from native endian to network endian.
pub fn toNetEndian(value: anytype) @TypeOf(value) {
    return bits.toBigEndian(value);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const bits = common.bits;
const util = common.util;
const urd = @import("urthr");

const PacketQueue = @import("net/queue.zig").PacketQueue;
