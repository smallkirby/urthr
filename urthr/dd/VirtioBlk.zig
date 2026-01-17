//! Virtio Block Device Driver.

const Self = @This();

/// Error type.
pub const Error = error{
    /// Invalid device.
    InvalidDevice,
    /// Device operation error.
    DeviceError,
    /// Error while I/O operation.
    IoError,
} || common.mem.Error;

/// Virtio device instance.
dev: *virtio,
/// Block device configuration.
config: Config,
/// Memory allocator.
allocator: Allocator,
/// Page allocator for DMA operations.
page_allocator: PageAllocator,

/// Sector size in bytes.
const sector_size = 512;
/// Index of the request queue.
const queue_index = 0;

// =============================================================
// API
// =============================================================

/// Initialize the virtio-blk device at the given MMIO base address.
///
/// The block device "manages" the given allocators.
pub fn init(base: usize, page_allocator: PageAllocator, allocator: Allocator) Error!Self {
    // Initialize virtio device.
    const dev = virtio.init(base, .block, page_allocator, allocator) catch |err|
        switch (err) {
            virtio.Error.InvalidDevice, virtio.Error.OutOfMemory => return Error.InvalidDevice,
            else => return Error.DeviceError,
        } orelse return Error.InvalidDevice;

    // Read device configuration.
    const config = readConfig(dev);
    log.info("capacity: {d} sectors ({d} MiB)", .{
        config.capacity,
        units.toMib(config.capacity * sector_size),
    });
    rtt.expectEqual(sector_size, config.blk_size);

    // Setup the request queue.
    dev.setupQueue(queue_index) catch |err| return switch (err) {
        virtio.Error.OutOfMemory => Error.OutOfMemory,
        else => Error.DeviceError,
    };

    // Complete device initialization.
    dev.finishInit();

    return .{
        .dev = dev,
        .config = config,
        .page_allocator = page_allocator,
        .allocator = allocator,
    };
}

/// Get the block device interface.
pub fn interface(self: *Self) block.Device {
    return .{
        .ptr = self,
        .vtable = &vtable_impl.vtable,
    };
}

// =============================================================
// Block Device Interface
// =============================================================

const vtable_impl = struct {
    const vtable = block.Device.Vtable{
        .blockSize = &getBlockSize,
        .blockCount = &getBlockCount,
        .read = &read,
    };

    /// Get the block size in bytes.
    fn getBlockSize(_: *const anyopaque) usize {
        return sector_size;
    }

    /// Get the total number of blocks.
    fn getBlockCount(ctx: *const anyopaque) u64 {
        const self: *const Self = @ptrCast(@alignCast(ctx));
        return self.config.capacity;
    }

    /// Read blocks from the device.
    fn read(ctx: *anyopaque, lba: block.Lba, buffer: []u8) block.Error!usize {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const num_sectors = buffer.len / sector_size;

        if (buffer.len % sector_size != 0) {
            return block.Error.InvalidArgument;
        }

        self.readSectors(lba, buffer, num_sectors) catch {
            return block.Error.IoError;
        };

        return buffer.len;
    }
};

// =============================================================
// Device Operations
// =============================================================

/// Read sectors from the device.
fn readSectors(self: *Self, sector: u64, buffer: []u8, count: usize) Error!void {
    const vq = self.dev.getQueue(queue_index) orelse return Error.DeviceError;

    // Allocate DMA-capable buffers.
    const data_buf_size = count * sector_size;
    const data = self.page_allocator.allocBytesV(data_buf_size) catch return Error.OutOfMemory;
    defer self.page_allocator.freeBytesV(data);

    const req = self.page_allocator.create(Request) catch return Error.OutOfMemory;
    defer self.page_allocator.destroy(req);

    const status = self.page_allocator.create(Status) catch return Error.OutOfMemory;
    defer self.page_allocator.destroy(status);

    req.* = .{
        .type = .read,
        .sector = sector,
    };

    // Build descriptor chain.
    const bufs = [_]virtio.Buffer{
        .{
            .addr = self.page_allocator.translateP(@intFromPtr(req)),
            .len = @sizeOf(Request),
            .write = false,
        },
        .{
            .addr = self.page_allocator.translateP(@intFromPtr(data.ptr)),
            .len = @intCast(data_buf_size),
            .write = true,
        },
        .{
            .addr = self.page_allocator.translateP(@intFromPtr(status)),
            .len = 1,
            .write = true,
        },
    };

    // Add buffers to the queue.
    vq.addBuf(&bufs) catch return Error.DeviceError;

    // Notify the device.
    self.dev.notifyQueue(queue_index);

    // Wait for completion.
    // TODO: should use interrupt.
    var timeout: u32 = 1_000_000; // 1 sec
    while (vq.getUsed() == null) {
        timeout -= 1;
        if (timeout == 0) {
            log.err("read timeout", .{});
            return Error.IoError;
        }

        arch.timer.spinWaitMicro(1);
    }

    // Check status.
    if (status.* != .ok) {
        log.err("read failed: status={d}", .{status.*});
        return Error.IoError;
    }

    // Copy data to user buffer.
    @memcpy(buffer[0..data_buf_size], data[0..data_buf_size]);
}

/// Read virtio-blk device configuration.
fn readConfig(dev: *virtio) Config {
    return .{
        .capacity = dev.readConfig(u64, 0),
        .size_max = dev.readConfig(u32, 8),
        .seg_max = dev.readConfig(u32, 12),
        .blk_size = dev.readConfig(u32, 20),
    };
}

/// Virtio-blk device configuration.
const Config = struct {
    /// Capacity in 512-byte sectors.
    capacity: u64,
    /// Maximum size of any single segment.
    size_max: u32,
    /// Maximum number of segments in a request.
    seg_max: u32,
    /// Block size in bytes.
    blk_size: u32,
};

/// Request header.
const Request = extern struct {
    /// Request type.
    type: RequestType,
    /// Reserved.
    _rsvd: u32 = 0,
    /// Sector number for read / write.
    sector: u64,
};

/// Request types.
const RequestType = enum(u32) {
    /// Read.
    read = 0,
    /// Write.
    write = 1,
    /// Cache flush.
    flush = 4,
    /// Get device ID.
    get_id = 8,
    /// Discard.
    discard = 11,
};

/// Status values.
const Status = enum(u8) {
    /// Request successful.
    ok = 0,
    /// Request failed.
    ioerr = 1,
    /// Request unsupported.
    unsupp = 2,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.vblk);
const arch = @import("arch").impl;
const common = @import("common");
const rtt = common.rtt;
const block = common.block;
const mmio = common.mmio;
const units = common.units;
const PageAllocator = common.PageAllocator;
const virtio = @import("virtio.zig");
