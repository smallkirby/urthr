//! Virtio GPU Driver.

const Self = @This();

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
/// Owned memory allocator.
allocator: Allocator,
/// DMA allocator for request buffers.
dma: DmaAllocator,

/// Mutex.
lock: Mutex = .{},
/// Event for signaling completion of I/O operations.
event: Event = .{},

/// Persistent DMA buffers.
bufs: struct {
    /// Buffer for GPU requests.
    req: DmaMemory,
    /// Buffer for GPU responses.
    res: DmaMemory,
},

/// Device ID of virtio GPU device.
pub const device_id = 16;
/// PCI device ID of virtio GPU device.
pub const pci_device_id = 0x1050;

/// Index of the request queue.
const queue_index = 0;
/// Length in bytes of the request and response DMA buffers.
const len_reqres_buf = 4096;

/// Feature bits supported by the virtio-gpu device.
pub const Features = packed struct(u64) {
    /// virgl 3D mode is supported.
    virgl: bool = false,
    /// EDID is supported.
    edid: bool = false,
    /// Assigning resources UUIDs for export to other virtio device is supported.
    resource_uuid: bool = false,
    /// Creating and using size-based blob resources is supported.
    resource_blob: bool = false,
    /// Multiple context types and synchronization timelines supported.
    context_init: bool = false,
    /// Not used.
    _5: u59 = 0,
};

/// Initialize the GPU device.
///
/// The gpu device "manages" the given allocators.
pub fn init(dev: virtio.Device, dma: DmaAllocator, allocator: Allocator) Error!Self {
    const config = readConfig(dev);
    log.info("#scanouts: {d}, #capsets: {d}", .{ config.num_scanouts, config.num_capsets });

    // Setup the request queue.
    dev.setupQueue(queue_index) catch |err| return switch (err) {
        virtio.Error.OutOfMemory => Error.OutOfMemory,
        else => Error.DeviceError,
    };

    // Complete device initialization.
    dev.finishInit();

    // Allocate DMA buffers.
    const req_mem = try dma.allocBytes(len_reqres_buf, .normal);
    const res_mem = try dma.allocBytes(len_reqres_buf, .normal);

    return .{
        .dev = dev,
        .allocator = allocator,
        .dma = dma,
        .bufs = .{
            .req = req_mem,
            .res = res_mem,
        },
    };
}

/// Register IRQ vector for the virtio-gpu device.
pub fn registerIrq(self: *Self, irq: urd.exception.Vector) void {
    urd.exception.setHandler(irq, .{
        .function = handleIrq,
        .ctx = self,
    }) catch {
        @panic("Failed to set IRQ handler for device");
    };
}

/// IRQ handler for the virtio-gpu device.
fn handleIrq(_: urd.exception.Vector, ctx: ?*anyopaque) void {
    if (ctx) |c| {
        const self: *Self = @ptrCast(@alignCast(c));

        // Reclaim completed descriptor chains from the used ring.
        if (self.dev.getQueue(queue_index)) |vq| {
            _ = vq.getUsed();
        }
        // Ack the interrupt.
        self.dev.ackInterrupt();
        // Wake any waiters for completed requests.
        _ = self.event.wake();
    }
}

// =============================================================
// Device Operations
// =============================================================

/// Read virtio-gpu device configuration.
fn readConfig(dev: virtio.Device) Config {
    return .{
        .events_read = dev.readConfig(u32, 0),
        .events_clear = dev.readConfig(u32, 4),
        .num_scanouts = dev.readConfig(u32, 8),
        .num_capsets = dev.readConfig(u32, 12),
    };
}

/// Display information for a single scanout.
pub const DisplayInfo = struct {
    /// ID of the display.
    id: u32,
    /// Rectangle defining the display area.
    rect: GpuRect,
};

/// Get a list of available display scanouts.
pub fn getDisplayInfo(self: *Self, allocator: Allocator) Error![]DisplayInfo {
    self.lock.lock();
    defer self.lock.unlock();

    // Construct request.
    const req_mem = self.bufs.req;
    const req: *Header = @ptrFromInt(req_mem.cpu);
    req.* = .{ .type = .get_display_info };
    self.dma.syncForDeviceAny(req);

    // Submit the request.
    const res = try self.submit(@sizeOf(Header));
    const gdi: *const GetDisplayInfoResp = @ptrCast(res);
    self.dma.syncForCpuAny(gdi);
    if (gdi.header.type != .ok_display_info) {
        return Error.DeviceError;
    }

    // Construct display information list from the response.
    var result = std.ArrayListUnmanaged(DisplayInfo).empty;
    errdefer result.deinit(allocator);
    for (gdi.pmodes, 0..) |pmode, i| {
        if (pmode.enabled != 0) {
            try result.append(allocator, .{
                .id = @intCast(i),
                .rect = pmode.rect,
            });
        }
    }
    return result.toOwnedSlice(allocator);
}

/// Create a 2D resource with the specified ID, format, width, and height.
pub fn createResource2d(self: *Self, id: u32, format: GpuFormat, width: u32, height: u32) Error!void {
    self.lock.lock();
    defer self.lock.unlock();

    // Construct request.
    const req_mem = self.bufs.req;
    const req: *ResourceCreate2dReq = @ptrFromInt(req_mem.cpu);
    req.* = .{
        .header = .{ .type = .resource_create_2d },
        .resource_id = id,
        .format = format,
        .width = width,
        .height = height,
    };
    self.dma.syncForDeviceAny(req);

    // Submit the request.
    const res = try self.submit(@sizeOf(ResourceCreate2dReq));
    self.dma.syncForCpuAny(res);
    if (res.type != .ok_nodata) {
        return Error.DeviceError;
    }
}

/// Attach backing memory to the specified 2D resource.
pub fn attachBacking(self: *Self, id: u32, entries: []const MemEntry) Error!void {
    rtt.expect(@sizeOf(ResourceAttachBackingReq) + @sizeOf(MemEntry) * entries.len <= len_reqres_buf);

    self.lock.lock();
    defer self.lock.unlock();

    // Construct request.
    const req_mem = self.bufs.req;
    const req: *ResourceAttachBackingReq = @ptrFromInt(req_mem.cpu);
    req.* = .{
        .header = .{ .type = .resource_attach_backing },
        .resource_id = id,
        .nr_entries = @intCast(entries.len),
    };
    for (entries, 0..) |entry, i| {
        req.entryAt(i).* = entry;
    }
    self.dma.syncForDevice(@intFromPtr(req), req.size());

    // Submit the request.
    const res = try self.submit(req.size());
    self.dma.syncForCpuAny(res);
    if (res.type != .ok_nodata) {
        return Error.DeviceError;
    }
}

/// Associate a scanout with a 2D resource and specify the rectangle to display.
pub fn setScanout(self: *Self, scanout_id: u32, resource_id: u32, rect: GpuRect) Error!void {
    self.lock.lock();
    defer self.lock.unlock();

    // Construct request.
    const req_mem = self.bufs.req;
    const req: *SetScanoutReq = @ptrFromInt(req_mem.cpu);
    req.* = .{
        .header = .{ .type = .set_scanout },
        .scanout_id = scanout_id,
        .resource_id = resource_id,
        .rect = rect,
    };
    self.dma.syncForDeviceAny(req);

    // Submit the request.
    const res = try self.submit(@sizeOf(SetScanoutReq));
    self.dma.syncForCpuAny(res);
    if (res.type != .ok_nodata) {
        return Error.DeviceError;
    }
}

/// Transfer the specified rectangle of a resource to the host.
pub fn transferToHost2d(self: *Self, id: u32, rect: GpuRect, offset: u64) Error!void {
    self.lock.lock();
    defer self.lock.unlock();

    // Construct request.
    const req_mem = self.bufs.req;
    const req: *TransferToHost2dReq = @ptrFromInt(req_mem.cpu);
    req.* = .{
        .header = .{ .type = .transfer_to_host_2d },
        .resource_id = id,
        .rect = rect,
        .offset = offset,
    };
    self.dma.syncForDeviceAny(req);

    // Submit the request.
    const res = try self.submit(@sizeOf(TransferToHost2dReq));
    self.dma.syncForCpuAny(res);
    if (res.type != .ok_nodata) {
        return Error.DeviceError;
    }
}

/// Flush the specified resource within the given rectangle.
pub fn flushResource(self: *Self, id: u32, rect: GpuRect) Error!void {
    self.lock.lock();
    defer self.lock.unlock();

    // Construct request.
    const req_mem = self.bufs.req;
    const req: *ResourceFlushReq = @ptrFromInt(req_mem.cpu);
    req.* = .{
        .header = .{ .type = .resource_flush },
        .resource_id = id,
        .rect = rect,
    };
    self.dma.syncForDeviceAny(req);

    // Submit the request.
    const res = try self.submit(@sizeOf(ResourceFlushReq));
    self.dma.syncForCpuAny(res);
    if (res.type != .ok_nodata) {
        return Error.DeviceError;
    }
}

/// Submit a request in the request buffer with the specified length.
///
/// Blocks until the request is completed or a timeout occurs.
///
/// Caller is responsible to flush a request buffer, and invalidate a response buffer.
/// Caller must take a lock.
fn submit(self: *Self, len: usize) Error!*const Header {
    const vq = self.dev.getQueue(queue_index) orelse return Error.DeviceError;

    // Build descriptor chain.
    const bufs = [_]virtio.Buffer{
        .{
            .addr = self.bufs.req.bus,
            .len = @intCast(len),
            .write = false,
        },
        .{
            .addr = self.bufs.res.bus,
            .len = @intCast(self.bufs.res.size),
            .write = true,
        },
    };

    // Add buffers to the queue.
    _ = vq.addBuf(&bufs) catch return Error.DeviceError;

    // Notify the device.
    self.dev.notifyQueue(queue_index);

    // Wait for completion.
    if (!self.event.wait(urd.time.getCurrentTimestamp() + 1 * std.time.ns_per_s)) {
        log.err("submit timeout", .{});
        return Error.IoError;
    }

    return @ptrFromInt(self.bufs.res.cpu);
}

// =============================================================
// Controls
// =============================================================

/// GPU device configuration structure.
const Config = struct {
    /// Signals pending events to the driver. RO for driver.
    events_read: u32,
    /// Clears pending events in the device. W1C.
    events_clear: u32,
    /// Specifies the maximum number of scanouts supported by the device. 1 to 16.
    num_scanouts: u32,
    /// Specifies the maximum number of capability sets supported by the device.
    num_capsets: u32,
};

/// GPU control header.
const Header = extern struct {
    /// Type of the driver request of device response.
    type: Command,
    /// Command-specific flags.
    flags: u32 = 0,
    /// If the driver sets VIRTIO_GPU_FLAG FENCE in request flag, the device MUST:
    /// - set VIRTIO_GPU_FLAG_FENCE in the response.
    /// - copy the content of the `fence_id` field from the request to the response.
    /// - send the response only after the command processing is complete.
    fence_id: u64 = 0,
    /// Rendering context (used in 3D mode only).
    ctx_id: u32 = 0,
    /// If VIRTIO_GPU_F_CONTEXT_INIT is supported, the driver MAY set VIRTIO_GPU_FLAG_INFO_RING_IDX bit in the request flags.
    /// In that case this field indicates the value of a context-specific ring index.
    ring_idx: u8 = 0,
    /// Not used.
    _padding: [3]u8 = @splat(0),
};

const Command = enum(u32) {
    // =============================================================
    // 2D commands

    get_display_info = 0x100,
    resource_create_2d = 0x101,
    resource_unref = 0x102,
    set_scanout = 0x103,
    resource_flush = 0x104,
    transfer_to_host_2d = 0x105,
    resource_attach_backing = 0x106,
    resource_detach_backing = 0x107,
    get_capset_info = 0x108,
    get_capset = 0x109,
    get_edid = 0x10A,
    resource_assign_uuid = 0x10B,
    resource_create_blob = 0x10C,
    set_scanout_blob = 0x10D,

    // =============================================================
    // 3D commands

    ctx_create = 0x200,
    ctx_destroy = 0x201,
    ctx_attach_resource = 0x202,
    ctx_detach_resource = 0x203,
    resource_create_3d = 0x204,
    transfer_to_host_3d = 0x205,
    transfer_from_host_3d = 0x206,
    submit_3d = 0x207,
    resource_map_blob = 0x208,
    resource_unmap_blob = 0x209,

    // =============================================================
    // Cursor commands

    update_cursor = 0x300,
    move_cursor = 0x301,

    // =============================================================
    // Success responses

    ok_nodata = 0x1100,
    ok_display_info = 0x1101,
    ok_capset_info = 0x1102,
    ok_capset = 0x1103,
    ok_edid = 0x1104,
    ok_resource_uuid = 0x1105,
    ok_map_info = 0x1106,

    // =============================================================
    // Error responses

    err_unspec = 0x1200,
    err_out_of_memory = 0x1201,
    err_invalid_scanout_id = 0x1202,
    err_invalid_resource_id = 0x1203,
    err_invalid_context_id = 0x1204,
    err_invalid_parameter = 0x1205,

    _,
};

/// GPU_MAX_SCANOUTS
const max_scanouts = 16;

/// Rectangle structure.
pub const GpuRect = extern struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// Response of GET_DISPLAY_INFO command.
const GetDisplayInfoResp = extern struct {
    /// Common header.
    header: Header,
    /// Per-scanout information.
    pmodes: [max_scanouts]DisplayOne,

    const DisplayOne = extern struct {
        /// Preferred scanout position and size.
        rect: GpuRect,
        /// Scanout is enabled or not.
        enabled: u32,
        /// Flags.
        flags: u32,
    };
};

/// Pixel format used for 2D resources.
pub const GpuFormat = enum(u32) {
    b8g8r8a8_unorm = 1,
    b8g8r8x8_unorm = 2,
    a8r8g8b8_unorm = 3,
    x8r8g8b8_unorm = 4,
    r8g8b8a8_unorm = 67,
    x8b8g8r8_unorm = 68,
    a8b8g8r8_unorm = 121,
    r8g8b8x8_unorm = 122,
};

/// Creates a 2D resource on the host with the specified width, height, and format.
const ResourceCreate2dReq = extern struct {
    /// Common header.
    header: Header,
    /// Resource ID generated by a guest.
    resource_id: u32,
    /// RGB format.
    format: GpuFormat,
    /// Width.
    width: u32,
    /// Height.
    height: u32,
};

pub const MemEntry = extern struct {
    /// Guest physical address of the memory to attach.
    addr: u64,
    /// Length of the backing memory.
    length: u32,
    /// Padding.
    _padding: u32 = 0,
};

/// Assigns backing memory to a resource.
const ResourceAttachBackingReq = extern struct {
    /// Common header.
    header: Header,
    /// Resource ID generated by a guest.
    resource_id: u32,
    /// Number of entries following this header.
    nr_entries: u32,
    /// Entries follow this header.
    __entries: [0]MemEntry = undefined,

    /// Get the entry at the specified index.
    fn entryAt(self: *const ResourceAttachBackingReq, index: usize) *MemEntry {
        rtt.expect(index < self.nr_entries);
        const ptr: usize = @intFromPtr(self) + @offsetOf(ResourceAttachBackingReq, "__entries") + @sizeOf(MemEntry) * index;
        return @ptrFromInt(ptr);
    }

    /// Get the size of this request.
    fn size(self: *const ResourceAttachBackingReq) usize {
        return @offsetOf(ResourceAttachBackingReq, "__entries") + @sizeOf(MemEntry) * self.nr_entries;
    }
};

/// Set the scanout parameters for a single output.
const SetScanoutReq = extern struct {
    /// Common header.
    header: Header,
    /// Rectangle specifying the scanout position and size.
    /// Must be covered by the underlying resource.
    rect: GpuRect,
    /// Scanout ID.
    scanout_id: u32,
    /// Resource to be scanned out from along with the rectangle.
    resource_id: u32,
};

/// Transfer from guest memory to host resource.
const TransferToHost2dReq = extern struct {
    /// Common header.
    header: Header,
    /// Rectangle specifying the transfer position and size.
    rect: GpuRect,
    /// Offset into the backing memory.
    offset: u64,
    /// Resource ID generated by a guest.
    resource_id: u32,
    /// Padding.
    _padding: u32 = 0,
};

/// Flush a scanout resource.
const ResourceFlushReq = extern struct {
    /// Common header.
    header: Header,
    /// Rectangle specifying the flush position and size.
    rect: GpuRect,
    /// Resource ID generated by a guest.
    resource_id: u32,
    /// Padding.
    _padding: u32 = 0,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.vgpu);
const common = @import("common");
const DmaAllocator = common.mem.DmaAllocator;
const DmaMemory = DmaAllocator.DmaMemory;
const rtt = common.rtt;
const urd = @import("urthr");
const Event = urd.sync.Event;
const Mutex = urd.sync.Mutex;
const virtio = @import("virtio.zig");
