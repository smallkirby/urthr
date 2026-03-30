//! Virtio Random Number Generator.

const Self = @This();

pub const Error = error{
    /// Given MMIO region is not a valid virtio RNG device.
    InvalidDevice,
    /// Device operation error.
    DeviceError,
    /// Memory allocation failed.
    OutOfMemory,
};

/// Virtio device instance.
dev: *virtio,

/// Index of the request queue.
const queue_index = 0;

/// Initialize a virtio RNG device at the given MMIO base address.
pub fn init(base: usize, page_allocator: PageAllocator, allocator: Allocator) Error!Self {
    // Validate the virtio device.
    const dev = virtio.init(
        base,
        .entropy,
        page_allocator,
        allocator,
    ) catch |err| (return switch (err) {
        virtio.Error.InvalidDevice => Error.InvalidDevice,
        else => Error.DeviceError,
    }) orelse return Error.InvalidDevice;

    // Setup the request queue.
    dev.setupQueue(queue_index) catch |err| return switch (err) {
        virtio.Error.OutOfMemory => Error.OutOfMemory,
        else => Error.DeviceError,
    };

    // Complete device initialization.
    dev.finishInit();

    return .{ .dev = dev };
}

/// Read random data from the device.
///
/// Returns a slice to the buffer containing the random data.
/// The buffer can be freed using the given allocator after use.
///
/// Note that the returned buffer size is equal to or greater than the requested size.
/// The rest of the buffer is not initialized and should not be used.
pub fn read(self: *Self, size: usize, allocator: PageAllocator) Error![]u8 {
    const dev = self.dev;

    // Enqueue the request.
    const vq = dev.getQueue(queue_index) orelse return Error.DeviceError;
    const out = allocator.allocBytesV(size) catch |err| return switch (err) {
        PageAllocator.Error.InvalidArgument => Error.DeviceError,
        PageAllocator.Error.OutOfMemory => Error.OutOfMemory,
    };
    errdefer allocator.freeBytesV(out);

    // Send request.
    const requests = [_]virtio.Buffer{
        .{
            .addr = @intFromPtr(allocator.translateP(out).ptr),
            .len = @intCast(size),
            .write = true,
        },
    };
    vq.addBuf(&requests) catch return Error.DeviceError;

    // Notify the device.
    self.dev.notifyQueue(queue_index);

    // Wait for completion.
    var timer = arch.timer.createTimer();
    timer.start(.ms(1));
    while (vq.getUsed() == null) {
        if (timer.expired()) @panic("virtio RNG read timed out");
        std.atomic.spinLoopHint();
    }

    return out;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const PageAllocator = common.mem.PageAllocator;
const arch = @import("arch").impl;
const virtio = @import("virtio.zig");
