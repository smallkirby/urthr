//! MMIO Transport Virtio driver.
//!
//! - ref. Virtual I/O Device (VIRTIO) Version 1.3

const Self = @This();

/// virtio MMIO module.
module: Module,
/// Device ID.
device_id: virtio.DeviceId,
/// Virtio version.
version: Version,
/// Virtqueues indexed by queue number.
queues: QueueMap,

/// Page allocator for DMA operations.
page_allocator: PageAllocator,
/// Memory allocator.
allocator: Allocator,

const QueueMap = std.AutoHashMap(u32, *virtio.Virtqueue);

// =============================================================
// Module Definition
// =============================================================

// The driver MUST only use 32 bit wide and aligned reads and writes to access the control registers.
const Module = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x000, MagicValue },
    .{ 0x004, Version },
    .{ 0x008, virtio.DeviceId },
    .{ 0x00c, VendorId },
    .{ 0x010, DeviceFeat },
    .{ 0x014, DeviceFeatSel },
    .{ 0x020, DriverFeat },
    .{ 0x024, DriverFeatSel },
    .{ 0x028, GuestPageSize },
    .{ 0x030, QueueSel },
    .{ 0x034, QueueNumMax },
    .{ 0x038, QueueNum },
    .{ 0x03c, QueueAlign },
    .{ 0x040, QueuePfn },
    .{ 0x044, QueueReady },
    .{ 0x050, QueueNotify },
    .{ 0x060, InterruptStatus },
    .{ 0x064, InterruptAck },
    .{ 0x070, Status },
    .{ 0x080, QueueDescLow },
    .{ 0x084, QueueDescHigh },
    .{ 0x090, QueueDriverLow },
    .{ 0x094, QueueDriverHigh },
    .{ 0x0a0, QueueDeviceLow },
    .{ 0x0a4, QueueDeviceHigh },
    .{ 0x0fc, ConfigGeneration },
    .{ 0x100, mmio.Marker(.config) },
});

/// Size in bytes of a single virtio MMIO device space.
pub const space_size = 0x200;

// =============================================================
// API
// =============================================================

/// Virtio magic value.
const virtio_magic: u32 = 0x74726976; // "virt"

/// Default queue size.
///
/// If the device supports smaller size, that size is used instead.
const default_queue_size = 128;

/// Initialize a virtio device.
///
/// After calling this function, caller can perform device-specific setup.
/// Caller must call `finishInit()` after device setup is complete.
///
/// Allocators are "managed" by the device instance.
///
/// Returns null if the device is not present or of the wrong type.
pub fn init(base: usize, expected: virtio.DeviceId, page_allocator: PageAllocator, allocator: Allocator) virtio.Error!?*Self {
    var mod = Module{};
    mod.setBase(base);

    // Check magic value.
    const magic = mod.read(MagicValue);
    if (magic.value != virtio_magic) {
        log.debug("Invalid virtio magic: 0x{X:0>8}", .{magic.value});
        return virtio.Error.InvalidDevice;
    }

    // Check version.
    const version = mod.read(Version);
    if (version != .modern and version != .legacy) {
        log.debug("Unsupported virtio version: {d}", .{@intFromEnum(version)});
        return virtio.Error.InvalidDevice;
    }

    // Check device type.
    const device_id = mod.read(virtio.DeviceId);
    if (device_id != expected) {
        return null;
    }

    // Allocate device state.
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .module = mod,
        .device_id = device_id,
        .version = version,
        .queues = QueueMap.init(allocator),
        .page_allocator = page_allocator,
        .allocator = allocator,
    };

    // Initialize the device.
    try self.initDevice();

    return self;
}

/// Initialize the device following virtio spec 3.1.1.
fn initDevice(self: *Self) virtio.Error!void {
    // Reset the device.
    self.module.writei(Status, 0);
    self.module.modify(Status, .{ .ack = true });
    self.module.modify(Status, .{ .driver = true });

    // Set guest page size before any queue is used.
    self.module.writei(GuestPageSize, virtio.page_size);

    // Read device feature bits.
    const device_features = if (self.version == .legacy)
        self.module.read(DeviceFeat).value
    else blk: {
        var features: u64 = 0;
        self.module.writei(DeviceFeatSel, 0);
        features |= @as(u64, self.module.read(DeviceFeat).value);
        self.module.writei(DeviceFeatSel, 1);
        features |= @as(u64, self.module.read(DeviceFeat).value) << 32;
        break :blk features;
    };

    // Negotiate features.
    // TODO: accept callback to delegate feature selection to caller.
    if (self.version == .legacy) {
        self.module.writei(DriverFeat, @as(u32, @truncate(device_features)));
    } else {
        const virtio_f_version1: u64 = 1 << 32;

        const features: u64 = device_features & virtio_f_version1;
        self.module.writei(DriverFeatSel, 0);
        self.module.writei(DriverFeat, bits.extract(u32, features, 0));
        self.module.writei(DriverFeatSel, 1);
        self.module.writei(DriverFeat, bits.extract(u32, features, 32));
    }

    // Set FEATURES_OK status bit (device does not accept features after this).
    self.module.modify(Status, .{ .features_ok = true });
}

/// Get a transport-agnostic interface backed by this instance.
pub fn interface(self: *Self) virtio.Device {
    return .{ .ptr = self, .vtable = &vtable };
}

// =============================================================
// VTable implementation
// =============================================================

const vtable = virtio.Device.Vtable{
    .setupQueue = setupQueue,
    .getQueue = getQueue,
    .notifyQueue = notifyQueue,
    .finishInit = finishInit,
    .readConfigBytes = readConfigBytes,
};

/// Setup a virtqueue.
fn setupQueue(ctx: *anyopaque, index: u32) virtio.Error!void {
    const self: *Self = @ptrCast(@alignCast(ctx));

    // Select the queue.
    self.module.writei(QueueSel, index);

    // Check if queue is already in use.
    if (self.queues.contains(index)) {
        return virtio.Error.QueueNotAvail;
    }
    if (self.version == .modern) {
        if (self.module.read(QueueReady).value != 0) {
            return virtio.Error.QueueNotAvail;
        }
    }

    // Get maximum queue size.
    const max_size: u16 = @intCast(self.module.read(QueueNumMax).value);
    if (max_size == 0) {
        return virtio.Error.QueueNotAvail;
    }

    // Select queue size.
    const queue_size = @min(max_size, default_queue_size);
    self.module.write(QueueNum, .{ .value = queue_size });
    log.debug("vq#{d}: max_size={d}, using={d}", .{ index, max_size, queue_size });

    // Allocate virtqueue.
    const vq = try virtio.Virtqueue.create(queue_size, self.allocator, self.page_allocator);
    errdefer vq.destroy(self.page_allocator, self.allocator);

    // Set queue addresses.
    const desc_addr = self.page_allocator.translateP(vq.getDescAddr());

    if (self.version == .legacy) {
        self.module.writei(QueueAlign, virtio.page_size);
        self.module.writei(QueuePfn, @as(u32, @intCast(desc_addr / virtio.page_size)));
    } else {
        const avail_addr = self.page_allocator.translateP(vq.getAvailAddr());
        const used_addr = self.page_allocator.translateP(vq.getUsedAddr());

        self.module.writei(QueueDescLow, @as(u32, @truncate(desc_addr)));
        self.module.writei(QueueDescHigh, @as(u32, @truncate(desc_addr >> 32)));
        self.module.writei(QueueDriverLow, @as(u32, @truncate(avail_addr)));
        self.module.writei(QueueDriverHigh, @as(u32, @truncate(avail_addr >> 32)));
        self.module.writei(QueueDeviceLow, @as(u32, @truncate(used_addr)));
        self.module.writei(QueueDeviceHigh, @as(u32, @truncate(used_addr >> 32)));

        self.module.writei(QueueReady, 1);
    }

    self.queues.put(index, vq) catch return virtio.Error.OutOfMemory;
}

/// Get a virtqueue by index.
fn getQueue(ctx: *anyopaque, index: u32) ?*virtio.Virtqueue {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.queues.get(index);
}

/// Notify the device that there are new buffers in the queue.
fn notifyQueue(ctx: *anyopaque, queue_index: u16) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.module.writei(QueueNotify, @as(u32, queue_index));
}

/// Notify the device that driver is ready.
fn finishInit(ctx: *anyopaque) void {
    const self: *const Self = @ptrCast(@alignCast(ctx));
    self.module.modify(Status, .{ .driver_ok = true });
}

/// Read bytes from the device config space at the given `offset`.
fn readConfigBytes(ptr: *anyopaque, offset: usize, buf: []u8) void {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    const cbase = self.module.getMarkerAddress(.config);
    const src: [*]const volatile u8 = @ptrFromInt(cbase + offset);
    for (buf, 0..) |*b, i| b.* = src[i];
}

// =============================================================
// MMIO Register Definitions
// =============================================================

/// Magic value register.
const MagicValue = packed struct(u32) {
    value: u32,
};

/// Version register.
const Version = enum(u32) {
    /// Legacy device.
    legacy = 1,
    /// Modern device.
    modern = 2,

    _,
};

/// Vendor ID register.
const VendorId = packed struct(u32) {
    value: u32,
};

/// Device features register.
const DeviceFeat = packed struct(u32) {
    value: u32,
};

/// Device feature selection register.
const DeviceFeatSel = packed struct(u32) {
    value: u32,
};

/// Driver features register.
const DriverFeat = packed struct(u32) {
    value: u32,
};

/// Driver feature selection register.
const DriverFeatSel = packed struct(u32) {
    value: u32,
};

/// Guest page size register (legacy only).
const GuestPageSize = packed struct(u32) {
    value: u32,
};

/// Queue selection register.
const QueueSel = packed struct(u32) {
    value: u32,
};

/// Maximum queue size register.
const QueueNumMax = packed struct(u32) {
    value: u32,
};

/// Queue size register.
const QueueNum = packed struct(u32) {
    value: u32,
};

/// Queue alignment register (legacy only).
const QueueAlign = packed struct(u32) {
    value: u32,
};

/// Queue PFN register (legacy only).
const QueuePfn = packed struct(u32) {
    value: u32,
};

/// Queue ready register.
const QueueReady = packed struct(u32) {
    value: u32,
};

/// Queue notify register.
const QueueNotify = packed struct(u32) {
    value: u32,
};

/// Interrupt status register.
const InterruptStatus = packed struct(u32) {
    value: u32,
};

/// Interrupt acknowledge register.
const InterruptAck = packed struct(u32) {
    value: u32,
};

/// Device status register.
pub const Status = packed struct(u32) {
    /// Guest OS has found the device and recognized it as a valid virtio device.
    ack: bool,
    /// Guest OS knows how to drive the device.
    driver: bool,
    /// Driver is set up and ready to drive the device.
    driver_ok: bool,
    /// Driver has acknowledged all the features it understands, and feature negotiation is complete.
    features_ok: bool,
    /// Reserved.
    _4: u2 = 0,
    /// Device has experienced an error from which it can't recover.
    device_needs_reset: bool,
    /// Something went wrong in the guest.
    failed: bool,
    /// Reserved.
    _8: u24 = 0,
};

/// Queue descriptor table address (low 32 bits).
const QueueDescLow = packed struct(u32) {
    value: u32,
};

/// Queue descriptor table address (high 32 bits).
const QueueDescHigh = packed struct(u32) {
    value: u32,
};

/// Queue available ring address (low 32 bits).
const QueueDriverLow = packed struct(u32) {
    value: u32,
};

/// Queue available ring address (high 32 bits).
const QueueDriverHigh = packed struct(u32) {
    value: u32,
};

/// Queue used ring address (low 32 bits).
const QueueDeviceLow = packed struct(u32) {
    value: u32,
};

/// Queue used ring address (high 32 bits).
const QueueDeviceHigh = packed struct(u32) {
    value: u32,
};

/// Configuration generation register.
const ConfigGeneration = packed struct(u32) {
    value: u32,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.virtio_mmio);
const Allocator = std.mem.Allocator;
const common = @import("common");
const bits = common.bits;
const mmio = common.mmio;
const PageAllocator = common.mem.PageAllocator;
const dd = @import("dd");
const virtio = dd.virtio;
