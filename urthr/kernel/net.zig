pub const arp = @import("net/arp.zig");
pub const dhcp = @import("net/dhcp.zig");
pub const ether = @import("net/ether.zig");
pub const icmp = @import("net/icmp.zig");
pub const ip = @import("net/ip.zig");
pub const udp = @import("net/udp.zig");
pub const util = @import("net/util.zig");

pub const Device = @import("net/Device.zig");
pub const Interface = @import("net/Interface.zig");
pub const Loopback = @import("net/Loopback.zig");
pub const NetBuffer = @import("net/NetBuffer.zig");

/// Registered network device list.
var device_list: Device.DeviceList = .{};

/// Packet queue for deferring RX processing.
var rxq: RxQueue = .{};
/// Packet queue for deferring TX processing.
var txq: TxQueue = .{};

/// Maximum number of packets to process per device in a single IRQ poll.
const poll_budget = 64;

/// Network error.
pub const Error = error{
    /// Given operation would cause duplication.
    Duplicated,
    /// Invalid address.
    InvalidAddress,
    /// Invalid packet data.
    InvalidPacket,
    /// No data available to read.
    NoData,
    /// Memory allocation failed.
    OutOfMemory,
    /// Address is being resolved. Wait and retry later.
    Resolving,
    /// Requested resource is unavailable.
    Unavailable,
    /// Given data, protocol, or operation is not supported.
    Unsupported,
    /// Operation timed out.
    Timeout,
};

/// Network protocols.
pub const Protocol = enum(u16) {
    /// IPv4
    ipv4,
    /// ARP
    arp,

    /// All other unrecognized protocols.
    _,

    /// Functions to handle the protocol data.
    pub const Vtable = struct {
        /// Process the incoming data.
        input: *const fn (dev: *Device, data: []const u8) Error!void,
    };

    /// Get the handler for the given protocol.
    fn getHandler(self: Protocol) ?Protocol.Vtable {
        return switch (self) {
            .ipv4 => ip.vtable,
            .arp => arp.vtable,
            else => null,
        };
    }
};

/// Initialize network subsystem.
pub fn init() Allocator.Error!void {
    try arp.cache.init(urd.mem.getGeneralAllocator());
}

/// Start running the network subsystem and register devices.
pub fn run() (Error || urd.sched.Error)!void {
    // Link-up all registered devices.
    var iter = device_list.iter();
    while (iter.next()) |device| {
        try device.open();
    }

    // Start the worker threads.
    _ = try urd.sched.spawn("net-rx", rxworker, .{});
    _ = try urd.sched.spawn("net-tx", txworker, .{});
}

/// Register a network device.
pub fn registerDevice(device: *Device) void {
    device_list.append(device);
}

const CmpInterfaceFn = *const fn (*const Interface, *const anyopaque) bool;

/// Find the interface that satisfies the given condition.
pub fn findInterface(cmp: CmpInterfaceFn, ctx: *const anyopaque) ?*Interface {
    var iter = device_list.iter();
    while (iter.next()) |device| {
        var ifiter = device.netif.iter();
        while (ifiter.next()) |netif| {
            if (cmp(netif, ctx)) {
                return netif;
            }
        }
    } else return null;
}

/// Handle incoming data to dispatch to the appropriate protocol handler.
pub fn handleInput(dev: *Device, prot: Protocol, data: []const u8) Error!void {
    if (prot.getHandler()) |handler| {
        // Delegate to the protocol handler
        return handler.input(dev, data);
    } else {
        // Ignore unrecognized protocol
        std.log.warn("Unsupported protocol: {d}", .{@intFromEnum(prot)});
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
        rxq.enqueue(.{
            .data = result.data,
            .device = device,
            .handle = result.handle,
        }) catch |err| switch (err) {
            // If the queue is full, just drop the packet.
            error.Full => {},
        };
    }
}

/// Enqueue a packet for deferred transmission.
///
/// The `buf` is an L3 packet without an L2 header.
/// The L2 header should be prepended by the thread that dequeues the packet.
///
/// Owns the given buffer on success.
/// Caller must not access the buffer after calling this function.
pub fn enqueueTx(device: *Device, dest: []const u8, prot: Protocol, buf: NetBuffer) Error!void {
    var pkt: TxQueue.TxPacket = .{
        .device = device,
        .dest_len = @intCast(dest.len),
        .protocol = prot,
        .buf = buf,
        .dest = undefined,
    };
    @memcpy(pkt.dest[0..dest.len], dest);
    txq.enqueue(pkt) catch return Error.Unavailable;
}

/// RX worker thread function.
///
/// Continuously processes incoming packets from the packet queue
/// and dispatches them to the appropriate device handlers.
///
/// Dequeued packets are released after processing.
/// Handlers must copy the packet data if they need to wait for the data to be consumed.
fn rxworker() void {
    while (true) {
        const pkt = rxq.dequeue();
        defer rxq.release(pkt);

        pkt.device.inputFrame(pkt.data);
    }
}

/// TX worker thread function.
///
/// Continuously dequeues pending transmit packets
/// and sends them through the associated device.
fn txworker() void {
    while (true) {
        var pkt = txq.dequeue();
        defer pkt.buf.deinit();

        pkt.device.output(
            pkt.dest[0..pkt.dest_len],
            pkt.protocol,
            &pkt.buf,
        ) catch |err| {
            std.log.err("TX failed: {}", .{err});
        };
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const bits = common.bits;
const urd = @import("urthr");

const RxQueue = @import("net/queue.zig").RxQueue;
const TxQueue = @import("net/queue.zig").TxQueue;
