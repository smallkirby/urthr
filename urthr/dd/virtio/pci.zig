//! PCI Transport Virtio driver.
//!
//! - ref. Virtual I/O Device (VIRTIO) Version 1.3

const Self = @This();

/// Common configuration registers.
ccfg: CommonReg,
/// Virtual base address of the notification structure.
notify: usize,
/// Stride in bytes to calculate the offset of a queue's notification register.
notify_off_mult: u32,
/// Virtual base address of the device-specific configuration space.
dcfg: usize,

/// Virtqueues indexed by queue number.
queues: QueueMap,

/// Page allocator for DMA operations.
page_allocator: PageAllocator,
/// Memory allocator.
allocator: Allocator,

const QueueMap = std.AutoHashMap(u32, *virtio.Virtqueue);

/// PCI vendor ID assigned to all virtio devices.
pub const vendor_id: u16 = 0x1AF4;

/// Default queue size.
///
/// If the device supports smaller size, that size is used instead.
const default_queue_size = 128;

/// Walk the PCI capability list and locate the virtio-pci capability structures.
pub fn findCaps(host: pci.Host, addr: pci.DevAddr) Caps {
    var result: Caps = .{};

    // Check if the device has a capability list.
    const io = host.getTypedIo(addr, pci.HeaderType0);
    const status = io.readReg(pci.HeaderCommandStatus);
    if (!status.capabilities_list) {
        return result;
    }

    // Iterate the capability list to find virtio capability.
    var offset: u12 = io.readReg(pci.HeaderCapPtr).cap_ptr;
    while (offset != 0) {
        const w0 = io.readAs(offset, CapWord0);
        defer offset = w0.cap_next;

        if (w0.cap_vndr != .vndr) {
            continue;
        }

        const w1 = io.readAs(offset + @sizeOf(@TypeOf(w0)), CapWord1);
        const region = Region{
            .bar = w1.bar,
            .offset = io.read(offset + 8),
            .length = io.read(offset + 12),
        };

        switch (w0.cfg_type) {
            .common => result.common = region,
            .notify => result.notify = .{
                .region = region,
                .notify_off_mult = io.read(offset + 16),
            },
            .isr => result.isr = region,
            .device => result.device = region,
            else => {},
        }
    }

    return result;
}

/// Initialize a virtio-pci (modern) device.
///
/// After calling this function, caller can perform device-specific setup.
/// Caller must call `finishInit()` after device setup is complete.
///
/// Allocators are "managed" by the device instance.
pub fn init(
    /// Host I/O interface to the PCI bus.
    host: pci.Host,
    /// Address of the virtio-pci device.
    addr: pci.DevAddr,
    /// Capability structures for the device.
    caps: Caps,
    /// Regions mapped by BARs.
    barmap: BarMap,
    /// Page allocator.
    page_allocator: PageAllocator,
    /// General-purpose memory allocator.
    allocator: Allocator,
) virtio.Error!?*Self {
    const region_ccfg = caps.common orelse {
        return virtio.Error.InvalidDevice;
    };
    const region_notify = caps.notify orelse {
        return virtio.Error.InvalidDevice;
    };
    const region_dcfg = caps.device orelse {
        return virtio.Error.InvalidDevice;
    };
    const base_ccfg = barmap.get(region_ccfg.bar) + region_ccfg.offset;
    const base_notify = barmap.get(region_notify.region.bar) + region_notify.region.offset;
    const base_dcfg = barmap.get(region_dcfg.bar) + region_dcfg.offset;

    // Enable memory space and bus mastering.
    const io = host.getTypedIo(addr, pci.HeaderType0);
    io.modifyReg(pci.HeaderCommandStatus, .{
        .memory_space_enable = true,
        .bus_master_enable = true,
    });

    // Construct the device instance.
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .ccfg = .new(base_ccfg),
        .notify = base_notify,
        .notify_off_mult = region_notify.notify_off_mult,
        .dcfg = base_dcfg,
        .queues = .init(allocator),
        .page_allocator = page_allocator,
        .allocator = allocator,
    };

    // Initialize device.
    try self.initDevice();

    return self;
}

/// Initialize the device following virtio spec 3.1.1.
fn initDevice(self: *Self) virtio.Error!void {
    // Reset the device.
    self.ccfg.writei(Status, 0);
    self.ccfg.modify(Status, .{ .ack = true });
    self.ccfg.modify(Status, .{ .driver = true });

    // Read device feature bits.
    const device_features = blk: {
        var value: u64 = 0;

        self.ccfg.writei(DeviceFeatSel, 0);
        value |= @as(u64, self.ccfg.read(DeviceFeat).value) << 0;
        self.ccfg.writei(DeviceFeatSel, 1);
        value |= @as(u64, self.ccfg.read(DeviceFeat).value) << 32;

        break :blk value;
    };

    // Negotiate features.
    // TODO: accept callback to delegate feature selection to caller.
    const virtio_f_version_1: u64 = 1 << 32;
    const driver_features: u64 = device_features & virtio_f_version_1;
    self.ccfg.writei(DriverFeatSel, 0);
    self.ccfg.writei(DriverFeat, bits.extract(u32, driver_features, 0));
    self.ccfg.writei(DriverFeatSel, 1);
    self.ccfg.writei(DriverFeat, bits.extract(u32, driver_features, 32));

    // Set FEATURES_OK status bit (device does not accept features after this).
    self.ccfg.modify(Status, .{ .features_ok = true });
    if (!self.ccfg.read(Status).features_ok) {
        log.err("Device rejected FEATURES_OK.", .{});
        return virtio.Error.InvalidDevice;
    }
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
    self.ccfg.writei(QueueSelect, @as(u16, @intCast(index)));

    // Check if queue is already in use.
    if (self.queues.contains(index)) {
        return virtio.Error.QueueNotAvail;
    }

    // Get maximum queue size.
    const max_size = self.ccfg.read(QueueSize).value;
    if (max_size == 0) {
        return virtio.Error.QueueNotAvail;
    }

    // Select queue size.
    const queue_size: u16 = @min(max_size, default_queue_size);
    self.ccfg.writei(QueueSize, queue_size);
    log.debug("vq#{d}: max_size={d}, using={d}", .{ index, max_size, queue_size });

    // Allocate virtqueue.
    const vq = try virtio.Virtqueue.create(
        queue_size,
        self.allocator,
        self.page_allocator,
    );
    errdefer vq.destroy(self.page_allocator, self.allocator);

    // Set queue addresses.
    self.ccfg.writei(QueueDesc, self.page_allocator.translateP(vq.getDescAddr()));
    self.ccfg.writei(QueueDriver, self.page_allocator.translateP(vq.getAvailAddr()));
    self.ccfg.writei(QueueDevice, self.page_allocator.translateP(vq.getUsedAddr()));
    self.ccfg.write(QueueEnable, .{ .value = .enable });

    self.queues.put(index, vq) catch return virtio.Error.OutOfMemory;
}

/// Get a virtqueue by index.
fn getQueue(ctx: *anyopaque, index: u32) ?*virtio.Virtqueue {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.queues.get(index);
}

/// Notify the device that there are new buffers in the queue.
fn notifyQueue(ctx: *anyopaque, queue_index: u16) void {
    const self: *const Self = @ptrCast(@alignCast(ctx));

    // Select the queue first.
    self.ccfg.writei(QueueSelect, queue_index);

    // Calculate the address of the queue's notification register.
    const notify_off: usize = self.ccfg.read(QueueNotifyOff).value;
    const addr = self.notify + notify_off * self.notify_off_mult;
    const ptr: *volatile u16 = @ptrFromInt(addr);

    // Notify the device.
    ptr.* = queue_index;
}

/// Notify the device that driver is ready.
fn finishInit(ctx: *anyopaque) void {
    const self: *const Self = @ptrCast(@alignCast(ctx));
    self.ccfg.modify(Status, .{ .driver_ok = true });
}

/// Read bytes from the device config space at the given `offset`.
fn readConfigBytes(ctx: *anyopaque, offset: usize, buf: []u8) void {
    const self: *const Self = @ptrCast(@alignCast(ctx));
    const src: [*]const volatile u8 = @ptrFromInt(self.dcfg + offset);
    for (buf, 0..) |*b, i| b.* = src[i];
}

// =============================================================
// Capability discovery
// =============================================================

/// Virtual base addresses of the BARs a device's capabilities live in.
pub const BarMap = struct {
    virt: [6]usize = @splat(0),

    pub fn get(self: BarMap, bar: usize) usize {
        return self.virt[bar];
    }
};

/// Location of a virtio-pci configuration structure within a BAR.
const Region = struct {
    /// BAR index containing the structure.
    bar: usize,
    /// Offset within the BAR.
    offset: u32,
    /// Length of the structure in bytes.
    length: u32,
};

/// Location of the notification structure.
const NotifyRegion = struct {
    /// Location of the notification structure.
    region: Region,
    /// Stride in bytes to calculate the offset of a queue's notification register.
    notify_off_mult: u32,
};

/// The virtio-pci configuration regions.
const Caps = struct {
    /// Common configuration.
    common: ?Region = null,
    /// Notificatoins.
    notify: ?NotifyRegion = null,
    /// ISR Status.
    isr: ?Region = null,
    /// Device-specific configuration.
    device: ?Region = null,
};

// =============================================================
// virtio defined

/// First word of a `virtio_pci_cap` structure in the PCI capability list.
const CapWord0 = packed struct(u32) {
    /// Generic PCI capability ID.
    cap_vndr: pci.CapId,
    /// Offset of the next capability.
    cap_next: u8,
    /// Length of this capability structure.
    cap_len: u8,
    /// Identifies the structure this capability points to.
    cfg_type: CfgType,
};

/// Second word of a `virtio_pci_cap` structure in the PCI capability list.
const CapWord1 = packed struct(u32) {
    /// Where to find the structure.
    bar: u8,
    /// Multiple capabilities of the same type.
    id: u8,
    /// Pad to full dword.
    _pad: u16 = 0,
};

/// Identifies which structure the capability points to.
const CfgType = enum(u8) {
    /// Common configuration.
    common = 1,
    /// Notifications.
    notify = 2,
    /// ISR Status.
    isr = 3,
    /// Device-specific configuration.
    device = 4,
    /// PCI configuration access.
    pci_cfg = 5,
    /// Shared memory region.
    shmem = 8,
    /// Vendor-specific data.
    vendor = 9,

    _,
};

// =============================================================
// Common Configuration Register
// =============================================================

/// Common configuration structure registers.
const CommonReg = mmio.Module(.{ .natural = u64 }, &.{
    // About the whole device.
    .{ 0x00, DeviceFeatSel },
    .{ 0x04, DeviceFeat },
    .{ 0x08, DriverFeatSel },
    .{ 0x0C, DriverFeat },
    .{ 0x10, ConfigMsix },
    .{ 0x12, NumQueues },
    .{ 0x14, Status },
    .{ 0x15, ConfigGeneration },

    // About a specific virtqueue.
    .{ 0x16, QueueSelect },
    .{ 0x18, QueueSize },
    .{ 0x1A, QueueMsixVector },
    .{ 0x1C, QueueEnable },
    .{ 0x1E, QueueNotifyOff },
    .{ 0x20, QueueDesc },
    .{ 0x28, QueueDriver },
    .{ 0x30, QueueDevice },
});

/// Driver uses to select which feature bits to use.
const DeviceFeatSel = packed struct(u32) {
    value: u32,
};

/// Device uses to report which feature bits it is offering.
const DeviceFeat = packed struct(u32) {
    value: u32,
};

/// Driver uses to select which feature bits to set.
const DriverFeatSel = packed struct(u32) {
    value: u32,
};

/// Driver writes to accept feature bits offered by the device.
const DriverFeat = packed struct(u32) {
    value: u32,
};

/// Set by driver to the MSI-X vector for configuration change notifications.
const ConfigMsix = packed struct(u16) {
    value: u16,
};

/// Device specifies the maximum number of virtqueues supported.
const NumQueues = packed struct(u16) {
    value: u16,
};

/// Driver writes the device status here.
///
/// Writing 0 into this field resets the device.
const Status = packed struct(u8) {
    /// Guest OS has found the device and recognized it as a valid virtio device.
    ack: bool = false,
    /// Guest OS knows how to drive the device.
    driver: bool = false,
    /// Driver is set up and ready to drive the device.
    driver_ok: bool = false,
    /// Driver has acknowledged all the features it understands, and feature negotiation is complete.
    features_ok: bool = false,
    /// Reserved.
    _4: u2 = 0,
    /// Device has experienced an error from which it can't recover.
    device_needs_reset: bool = false,
    /// Something went wrong in the guest, and it has given up on the device.
    failed: bool = false,
};

/// Configuration atomicity value.
///
/// Device changes this every time the configuration noticeably changes.
const ConfigGeneration = packed struct(u8) {
    value: u8,
};

/// Queue Select.
///
/// Driver selects which virtqueue the following fields refer to.
const QueueSelect = packed struct(u16) {
    value: u16,
};

/// Queue Size.
///
/// On reset, specifies the maximum number of queue size supported by the device.
const QueueSize = packed struct(u16) {
    value: u16,
};

/// Set by the driver to the MSI-X vector for virtqueue notifications.
const QueueMsixVector = packed struct(u16) {
    value: u16,
};

/// Driver uses to selectively prevent the device from executing requests from this virtqueue.
const QueueEnable = packed struct(u16) {
    value: enum(u16) {
        disabled = 0,
        enable = 1,
        _,
    },
};

/// Driver reads to calculate the offset from start of Notification structure at which this virtqueue is located.
const QueueNotifyOff = packed struct(u16) {
    value: u16,
};

/// The driver writes the physical address of Descriptor Area.
const QueueDesc = packed struct(u64) {
    value: u64,
};

/// The driver writes the physical address of Driver Area.
const QueueDriver = packed struct(u64) {
    value: u64,
};

/// Driver writes the physical address of Device Area.
const QueueDevice = packed struct(u64) {
    value: u64,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.vpci);
const Allocator = std.mem.Allocator;
const common = @import("common");
const bits = common.bits;
const mmio = common.mmio;
const PageAllocator = common.mem.PageAllocator;
const dd = @import("dd");
const pci = dd.pci;
const virtio = dd.virtio;
