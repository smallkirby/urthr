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
dev: virtio.Device,
/// Block device configuration.
config: Config,
/// Memory allocator.
allocator: Allocator,
/// DMA allocator for request buffers.
dma: DmaAllocator,
/// Serializes access to the queue.
lock: Mutex = .{},

/// Sector size in bytes.
const sector_size = 512;
/// Index of the request queue.
const queue_index = 0;

/// PCI device ID of a legacy virtio-blk device.
pub const pci_device_id_legacy: u16 = 0x1001;
/// PCI device ID of a modern virtio-blk device.
pub const pci_device_id_modern: u16 = 0x1042;

// =============================================================
// API
// =============================================================

/// Initialize the virtio-blk device.
///
/// The block device "manages" the given allocators.
pub fn init(dev: virtio.Device, dma: DmaAllocator, allocator: Allocator) Error!Self {
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
        .dma = dma,
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
        .write = &write,
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

    /// Write blocks to the device.
    fn write(ctx: *anyopaque, lba: block.Lba, data: []const u8) block.Error!usize {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const num_sectors = data.len / sector_size;

        if (data.len % sector_size != 0) {
            return block.Error.InvalidArgument;
        }

        self.writeSectors(lba, data, num_sectors) catch {
            return block.Error.IoError;
        };

        return data.len;
    }
};

// =============================================================
// Device Operations
// =============================================================

/// Read sectors from the device.
fn readSectors(self: *Self, sector: u64, buffer: []u8, count: usize) Error!void {
    self.lock.lock();
    defer self.lock.unlock();

    const vq = self.dev.getQueue(queue_index) orelse return Error.DeviceError;

    // Allocate DMA-capable buffers.
    const data_buf_size = count * sector_size;
    const data_mem = try self.dma.allocBytes(data_buf_size, .normal);
    defer self.dma.freeBytes(data_mem);

    const req_mem = try self.dma.allocBytes(@sizeOf(Request), .normal);
    defer self.dma.freeBytes(req_mem);
    const req: *Request = @ptrFromInt(req_mem.cpu);

    const status_mem = try self.dma.allocBytes(@sizeOf(Status), .normal);
    defer self.dma.freeBytes(status_mem);
    const status: *Status = @ptrFromInt(status_mem.cpu);

    req.* = .{
        .type = .read,
        .sector = sector,
    };
    self.dma.syncForDevice(req_mem.cpu, @sizeOf(Request));

    // Build descriptor chain.
    const bufs = [_]virtio.Buffer{
        .{
            .addr = req_mem.bus,
            .len = @sizeOf(Request),
            .write = false,
        },
        .{
            .addr = data_mem.bus,
            .len = @intCast(data_buf_size),
            .write = true,
        },
        .{
            .addr = status_mem.bus,
            .len = 1,
            .write = true,
        },
    };

    // Add buffers to the queue.
    _ = vq.addBuf(&bufs) catch return Error.DeviceError;

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
    self.dma.syncForCpu(status_mem.cpu, @sizeOf(Status));
    if (status.* != .ok) {
        log.err("read failed: status={d}", .{status.*});
        return Error.IoError;
    }

    // Copy data to user buffer.
    self.dma.syncForCpu(data_mem.cpu, data_buf_size);
    @memcpy(buffer[0..data_buf_size], @as([*]const u8, @ptrFromInt(data_mem.cpu))[0..data_buf_size]);
}

/// Read virtio-blk device configuration.
fn readConfig(dev: virtio.Device) Config {
    return .{
        .capacity = dev.readConfig(u64, 0),
        .size_max = dev.readConfig(u32, 8),
        .seg_max = dev.readConfig(u32, 12),
        .blk_size = dev.readConfig(u32, 20),
    };
}

/// Write sectors to the device.
fn writeSectors(self: *Self, sector: u64, data: []const u8, count: usize) Error!void {
    self.lock.lock();
    defer self.lock.unlock();

    const vq = self.dev.getQueue(queue_index) orelse return Error.DeviceError;

    if (data.len != count * sector_size) {
        return Error.InvalidDevice;
    }

    // Allocate DMA-capable buffers.
    const data_mem = try self.dma.allocBytes(data.len, .normal);
    defer self.dma.freeBytes(data_mem);
    @memcpy(@as([*]u8, @ptrFromInt(data_mem.cpu))[0..data.len], data);
    self.dma.syncForDevice(data_mem.cpu, data.len);

    const req_mem = try self.dma.allocBytes(@sizeOf(Request), .normal);
    defer self.dma.freeBytes(req_mem);
    const req: *Request = @ptrFromInt(req_mem.cpu);

    const status_mem = try self.dma.allocBytes(@sizeOf(Status), .normal);
    defer self.dma.freeBytes(status_mem);
    const status: *Status = @ptrFromInt(status_mem.cpu);

    req.* = .{
        .type = .write,
        .sector = sector,
    };
    self.dma.syncForDevice(req_mem.cpu, @sizeOf(Request));

    // Build descriptor chain.
    const bufs = [_]virtio.Buffer{
        .{
            .addr = req_mem.bus,
            .len = @sizeOf(Request),
            .write = false,
        },
        .{
            .addr = data_mem.bus,
            .len = @intCast(data.len),
            .write = false,
        },
        .{
            .addr = status_mem.bus,
            .len = 1,
            .write = true,
        },
    };

    // Add buffers to the queue.
    _ = vq.addBuf(&bufs) catch return Error.DeviceError;

    // Notify the device.
    self.dev.notifyQueue(queue_index);

    // Wait for completion.
    // TODO: should use interrupt.
    var timeout: u32 = 1_000_000; // 1 sec
    while (vq.getUsed() == null) {
        timeout -= 1;
        if (timeout == 0) {
            log.err("write timeout", .{});
            return Error.IoError;
        }

        arch.timer.spinWaitMicro(1);
    }

    // Check status.
    self.dma.syncForCpu(status_mem.cpu, @sizeOf(Status));
    if (status.* != .ok) {
        log.err("write failed: status={d}", .{status.*});
        return Error.IoError;
    }
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
const DmaAllocator = common.mem.DmaAllocator;
const virtio = @import("virtio.zig");
const urd = @import("urthr");
const Mutex = urd.sync.Mutex;
