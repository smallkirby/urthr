//! Virtio Network Device Driver.
//!
//! Implements `net.Device` interface.

const Self = @This();

/// Error type.
pub const Error = error{
    /// Invalid device.
    InvalidDevice,
    /// Device operation error.
    DeviceError,
} || common.mem.Error;

/// Virtio device instance.
dev: virtio.Device,
/// RX buffers.
rx_buffers: [num_rx_bufs]RxBuffer,
/// Maps a descriptor ID currently posted to the RX queue to its index into `rx_buffers`.
desc_to_buf: [num_rx_bufs]usize,
/// TX buffer.
///
/// Currently, transmission is synchronous and only one packet can be transmitted at a time.
tx_buffer: []u8,
/// Page allocator for DMA-capable memory.
page_allocator: PageAllocator,

/// Index of the RX queue.
///
/// The ordering of RX and TX queue is fixed by the virtio spec.
pub const rxq_idx = 0;
/// Index of the TX queue.
const txq_idx = 1;

/// Number of RX buffers in a queue.
const num_rx_bufs = 32;

/// Maximum Transmission Unit in bytes.
pub const mtu = 1500;
/// Maximum Transmission Unit in bytes including the Ethernet header.
pub const mtu_all = mtu + 14; // + is Ethernet header size

/// Size of a single RX/TX buffer, including the virtio-net header.
const buffer_size = @sizeOf(NetHdr) + mtu_all;
comptime {
    if (buffer_size < 1526) {
        @compileError("RX buffer size must be at least 1526 bytes to comply with spec.");
    }
}

/// PCI device ID of a legacy virtio-net device.
pub const pci_device_id_legacy: u16 = 0x1000;
/// PCI device ID of a modern virtio-net device.
pub const pci_device_id_modern: u16 = 0x1041;

/// A single pre-allocated RX buffer.
const RxBuffer = struct {
    /// Virtual address of the buffer.
    virt: usize,
    /// Physical address of the buffer.
    phys: u64,
};

/// Virtio-net per-packet header.
///
/// All incoming and outgoing packets are preceded by this header.
const NetHdr = extern struct {
    /// Flags.
    flags: u8 = 0,
    ///
    gso_type: u8 = 0,
    /// The header length that needs to be replicated for each packet.
    hdr_len: u16 = 0,
    /// Maximum size of each packet beyond the header.
    gso_size: u16 = 0,
    /// Offset within the packet to begin checksumming.
    ///
    /// Used only when VIRTIO_NET_HDR_F_NEEDS_CSUM is set in flags.
    csum_start: u16 = 0,
    /// How many bytes after `csum_start` to include in the checksum.
    csum_offset: u16 = 0,
    /// On TX, unused.
    num_buffers: u16 = 0,
};

// =============================================================
// API
// =============================================================

/// Create a new network device for a virtio-net controller.
///
/// Memory allocated for this driver will be managed by the given allocators.
pub fn new(dev: virtio.Device, page_allocator: PageAllocator, allocator: Allocator) Error!*net.Device {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    const netdev = try allocator.create(net.Device);
    errdefer allocator.destroy(netdev);

    // Setup the RX and TX queues.
    dev.setupQueue(rxq_idx) catch |err| return switch (err) {
        virtio.Error.OutOfMemory => Error.OutOfMemory,
        else => Error.DeviceError,
    };
    dev.setupQueue(txq_idx) catch |err| return switch (err) {
        virtio.Error.OutOfMemory => Error.OutOfMemory,
        else => Error.DeviceError,
    };
    dev.finishInit();

    self.* = .{
        .dev = dev,
        .rx_buffers = undefined,
        .desc_to_buf = undefined,
        .tx_buffer = try page_allocator.allocBytesV(buffer_size),
        .page_allocator = page_allocator,
    };
    errdefer page_allocator.freeBytesV(self.tx_buffer);

    // Populate RX buffers and post them to the device.
    try self.fillRxQueue();

    // Read the MAC address from the device config space.
    const mac = MacAddr{ .value = dev.readConfig([MacAddr.length]u8, 0) };
    log.info("MAC address: {f}", .{mac});

    // Initialize net device.
    netdev.* = .{
        .ctx = @ptrCast(self),
        .vtable = vtable,
        .flags = .{ .up = false, .need_arp = true },
        .mtu = mtu_all,
        .dev_type = .ether,
        .addr = undefined,
        .addr_len = MacAddr.length,
        .broadcast = undefined,
    };
    @memcpy(netdev.addr[0..MacAddr.length], &mac.value);
    @memcpy(netdev.broadcast[0..MacAddr.length], &MacAddr.broadcast.value);

    return netdev;
}

/// Allocate and post the initial set of write-only RX buffers.
fn fillRxQueue(self: *Self) Error!void {
    const vq = self.dev.getQueue(rxq_idx) orelse return Error.DeviceError;

    for (&self.rx_buffers, 0..) |*buf, index| {
        const mem = try self.page_allocator.allocBytesV(buffer_size);
        buf.* = .{
            .virt = @intFromPtr(mem.ptr),
            .phys = self.page_allocator.translateP(@intFromPtr(mem.ptr)),
        };

        const id = vq.addBuf(&[_]virtio.Buffer{.{
            .addr = buf.phys,
            .len = buffer_size,
            .write = true,
        }}) catch return Error.DeviceError;
        self.desc_to_buf[id] = index;
    }

    self.dev.notifyQueue(rxq_idx);
}

// =============================================================
// Network Interface
// =============================================================

const vtable: net.Device.Vtable = .{
    .prependHeader = net.ether.prependHeader,
    .transmit = transmitImpl,
    .poll = pollImpl,
    .releaseRxBuf = releaseRxBufImpl,
};

/// Get a incoming packet if available.
fn pollImpl(dev: *net.Device) net.Error!?net.Device.PollResult {
    const self: *Self = @ptrCast(@alignCast(dev.ctx));
    const vq = self.dev.getQueue(rxq_idx) orelse return null;

    const id, const len = vq.getUsed() orelse return null;
    if (len < @sizeOf(NetHdr)) {
        return null;
    }

    // Remove virtio-net header and return the packet data.
    const index = self.desc_to_buf[id];
    const buf = self.rx_buffers[index];
    const ptr: [*]const u8 = @ptrFromInt(buf.virt + @sizeOf(NetHdr));
    return .{
        .data = ptr[0 .. len - @sizeOf(NetHdr)],
        .handle = index,
    };
}

/// Refill the RX queue with a buffer identified by the given handle.
fn releaseRxBufImpl(dev: *net.Device, handle: usize) void {
    const self: *Self = @ptrCast(@alignCast(dev.ctx));
    const vq = self.dev.getQueue(rxq_idx) orelse return;
    const buf = self.rx_buffers[handle];

    const id = vq.addBuf(&[_]virtio.Buffer{.{
        .addr = buf.phys,
        .len = buffer_size,
        .write = true,
    }}) catch |err| {
        log.err("failed to refil RX buffer: {t}", .{err});
        return;
    };
    self.desc_to_buf[id] = handle;
    self.dev.notifyQueue(rxq_idx);
}

/// Send a packet to the device.
fn transmitImpl(dev: *net.Device, _: net.Protocol, buf: *net.NetBuffer) net.Error!void {
    const self: *Self = @ptrCast(@alignCast(dev.ctx));
    const vq = self.dev.getQueue(txq_idx) orelse return net.Error.Unavailable;

    const data = buf.data();
    if (data.len == 0 or data.len > mtu_all) {
        return net.Error.InvalidPacket;
    }

    // Prepend virtio-net header to the packet.
    const hdr: NetHdr = .{};
    @memcpy(self.tx_buffer[0..@sizeOf(NetHdr)], std.mem.asBytes(&hdr));
    @memcpy(self.tx_buffer[@sizeOf(NetHdr)..][0..data.len], data);

    // Add the TX buffer to the queue.
    _ = vq.addBuf(&[_]virtio.Buffer{.{
        .addr = self.page_allocator.translateP(@intFromPtr(self.tx_buffer.ptr)),
        .len = @intCast(@sizeOf(NetHdr) + data.len),
        .write = false,
    }}) catch return net.Error.Unavailable;

    self.dev.notifyQueue(txq_idx);

    // Wait for completion.
    // TODO: should use interrupt.
    var timer = arch.timer.createTimer();
    timer.start(.ms(500));
    while (vq.getUsed() == null) {
        if (timer.expired()) return net.Error.Timeout;
        std.atomic.spinLoopHint();
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.vnet);
const arch = @import("arch").impl;
const common = @import("common");
const PageAllocator = common.mem.PageAllocator;
const urd = @import("urthr");
const net = urd.net;
const MacAddr = net.ether.MacAddr;
const virtio = @import("../virtio.zig");
