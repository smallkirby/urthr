//! MMIO Transport Virtio driver.
//!
//! - ref. Virtual I/O Device (VIRTIO) Version 1.3

const Self = @This();

pub const Error = error{
    /// Invalid or unrecognized device.
    InvalidDevice,
    /// Specified queue is already in use or not available.
    QueueNotAvail,
    /// Virtqueue is full.
    QueueFull,
    /// Invalid argument.
    InvalidArgument,
    /// Memory allocation failed.
    OutOfMemory,
};

/// virtio MMIO module.
module: virtio,
/// Device ID.
device_id: DeviceId,
/// Virtio version.
version: Version,
/// Virtqueues indexed by queue number.
queues: QueueMap,

/// Page allocator for DMA operations.
page_allocator: PageAllocator,
/// Memory allocator.
allocator: Allocator,

const QueueMap = std.AutoHashMap(u32, *Virtqueue);

// =============================================================
// Module Definition
// =============================================================

// The driver MUST only use 32 bit wide and aligned reads and writes to access the control registers.
const virtio = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x000, MagicValue },
    .{ 0x004, Version },
    .{ 0x008, DeviceId },
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
pub const mmio_space_size = 0x200;

// =============================================================
// API
// =============================================================

/// Virtio magic value.
const virtio_magic: u32 = 0x74726976; // "virt"

/// Default queue size.
///
/// If the device supports smaller size, that size is used instead.
const default_queue_size = 128;

/// Page size for virtqueue alignment.
const page_size = 4096;

/// Virtio device ID.
pub const DeviceId = enum(u32) {
    /// Reserved (invalid)
    invalid = 0,
    /// Network device
    network = 1,
    /// Block device
    block = 2,
    /// Console
    console = 3,
    /// Entropy source
    entropy = 4,
    /// Memory ballooning (traditional)
    balloon = 5,
    /// ioMemory
    io_memory = 6,
    /// rpmsg
    rpmsg = 7,
    /// SCSI host
    scsi_host = 8,
    /// 9P transport
    transport_9p = 9,
    /// mapc80211 wlan
    mac80211_wlan = 10,
    /// rproc serial
    rproc_serial = 11,
    /// virtio CAIF
    caif = 12,
    /// memory balloon
    memory_balloon = 13,
    /// GPU device
    gpu = 16,
    /// Timer/Clock device
    timer = 17,
    /// Input device
    input = 18,
    /// Socket device
    socket = 19,
    /// Crypto device
    crypto = 20,
    /// Signal Distribution Module
    signal_dist = 21,
    /// pstore device
    pstore = 22,
    /// IOMMU device
    iommu = 23,
    /// Memory device
    mem = 24,
    /// Sound device
    sound = 25,
    /// file system device
    fs = 26,
    /// PMEM device
    pmem = 27,
    /// RPMB device
    rpmb = 28,
    /// mac80211 hwsim wireless simulation device
    mac80211_hwsim = 29,
    /// Video encoder device
    venc = 30,
    /// Video decoder device
    vdec = 31,
    /// SCMI device
    scmi = 32,
    /// NitroSecureModule
    nitro_secure = 33,
    /// I2C adapter
    i2c = 34,
    /// Watchdog
    watchdog = 35,
    /// CAN device
    can = 36,
    /// Parameter Server
    parameter = 38,
    /// Audio policy device
    audio_policy = 39,
    /// Bluetooth device
    bluetooth = 40,
    /// GPIO device
    gpio = 41,
    /// RDMA device
    rdma = 42,
    /// Camera device
    camera = 43,
    /// ISM device
    ism = 44,
    /// SPI master
    spi = 45,

    _,
};

/// Initialize a virtio device.
///
/// After calling this function, caller can perform device-specific setup.
/// Caller must call `finishInit()` after device setup is complete.
///
/// Allocators are "managed" by the device instance.
///
/// Returns null if the device is not present or of the wrong type.
pub fn init(base: usize, expected: DeviceId, page_allocator: PageAllocator, allocator: Allocator) Error!?*Self {
    var mod = virtio{};
    mod.setBase(base);

    // Check magic value.
    const magic = mod.read(MagicValue);
    if (magic.value != virtio_magic) {
        log.debug("Invalid virtio magic: 0x{X:0>8}", .{magic.value});
        return Error.InvalidDevice;
    }

    // Check version.
    const version = mod.read(Version);
    if (version != .modern and version != .legacy) {
        log.debug("Unsupported virtio version: {d}", .{@intFromEnum(version)});
        return Error.InvalidDevice;
    }

    // Check device type.
    const device_id = mod.read(DeviceId);
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
fn initDevice(self: *Self) Error!void {
    // Reset the device.
    self.module.write(Status, 0);
    self.module.modify(Status, .{ .ack = true });
    self.module.modify(Status, .{ .driver = true });

    // Set guest page size before any queue is used.
    self.module.write(GuestPageSize, page_size);

    // Read device feature bits.
    const device_features = if (self.version == .legacy)
        self.module.read(DeviceFeat).value
    else blk: {
        var features: u64 = 0;
        self.module.write(DeviceFeatSel, 0);
        features |= @as(u64, self.module.read(DeviceFeat).value);
        self.module.write(DeviceFeatSel, 1);
        features |= @as(u64, self.module.read(DeviceFeat).value) << 32;
        break :blk features;
    };

    // Negotiate features.
    // TODO: accept callback to delegate feature selection to caller.
    if (self.version == .legacy) {
        self.module.write(DriverFeat, @as(u32, @truncate(device_features)));
    } else {
        const virtio_f_version1: u64 = 1 << 32;

        const features: u64 = device_features & virtio_f_version1;
        self.module.write(DriverFeatSel, 0);
        self.module.write(DriverFeat, bits.extract(u32, features, 0));
        self.module.write(DriverFeatSel, 1);
        self.module.write(DriverFeat, bits.extract(u32, features, 32));
    }

    // Set FEATURES_OK status bit (device does not accept features after this).
    self.module.modify(Status, .{ .features_ok = true });
}

/// Setup a virtqueue.
pub fn setupQueue(self: *Self, index: u32) Error!void {
    // Select the queue.
    self.module.write(QueueSel, index);

    // Check if queue is already in use.
    if (self.queues.contains(index)) {
        return Error.QueueNotAvail;
    }
    if (self.version == .modern) {
        if (self.module.read(QueueReady).value != 0) {
            return Error.QueueNotAvail;
        }
    }

    // Get maximum queue size.
    const max_size: u16 = @intCast(self.module.read(QueueNumMax).value);
    if (max_size == 0) {
        return Error.QueueNotAvail;
    }

    // Select queue size.
    const queue_size = @min(max_size, default_queue_size);
    self.module.write(QueueNum, QueueNum{ .value = queue_size });
    log.debug("vq#{d}: max_size={d}, using={d}", .{ index, max_size, queue_size });

    // Allocate virtqueue.
    const vq = try Virtqueue.create(queue_size, self.allocator, self.page_allocator);
    errdefer vq.destroy(self.page_allocator, self.allocator);

    // Set queue addresses.
    const desc_addr = self.page_allocator.translateP(vq.getDescAddr());

    if (self.version == .legacy) {
        self.module.write(QueueAlign, page_size);
        self.module.write(QueuePfn, @as(u32, @intCast(desc_addr / page_size)));
    } else {
        const avail_addr = self.page_allocator.translateP(vq.getAvailAddr());
        const used_addr = self.page_allocator.translateP(vq.getUsedAddr());

        self.module.write(QueueDescLow, @as(u32, @truncate(desc_addr)));
        self.module.write(QueueDescHigh, @as(u32, @truncate(desc_addr >> 32)));
        self.module.write(QueueDriverLow, @as(u32, @truncate(avail_addr)));
        self.module.write(QueueDriverHigh, @as(u32, @truncate(avail_addr >> 32)));
        self.module.write(QueueDeviceLow, @as(u32, @truncate(used_addr)));
        self.module.write(QueueDeviceHigh, @as(u32, @truncate(used_addr >> 32)));

        self.module.write(QueueReady, 1);
    }

    self.queues.put(index, vq) catch return Error.OutOfMemory;
}

/// Get a virtqueue by index.
pub fn getQueue(self: *Self, index: u32) ?*Virtqueue {
    return self.queues.get(index);
}

/// Notify the device that driver is ready.
pub fn finishInit(self: *const Self) void {
    self.module.modify(Status, .{ .driver_ok = true });
}

/// Notify the device that there are new buffers in the queue.
pub fn notifyQueue(self: *const Self, queue_index: u16) void {
    self.module.write(QueueNotify, @as(u32, queue_index));
}

/// Read a value from the device config space.
///
/// Caller must ensure that `offset` is naturally aligned for type `T`.
pub fn readConfig(self: *const Self, comptime T: type, offset: usize) T {
    const config_base = self.module.getMarkerAddress(.config);
    const ptr: *const volatile T = @ptrFromInt(config_base + offset);

    return ptr.*;
}

// =============================================================
// Virtqueue Implementation
// =============================================================

/// Virtqueue descriptor.
pub const Desc = extern struct {
    /// Physical address of the buffer.
    addr: u64,
    /// Length of the buffer.
    len: u32,
    /// Descriptor flags.
    flags: Flags,
    /// Next descriptor index if NEXT flag is set.
    next: u16,

    /// Virtqueue descriptor flags.
    pub const Flags = packed struct(u16) {
        /// Buffer continues via the next field.
        next: bool = false,
        /// Buffer is write-only (device writes, driver reads).
        write: bool = false,
        /// Buffer contains a list of buffer descriptors.
        indirect: bool = false,
        /// Reserved.
        _rsvd: u13 = 0,
    };

    comptime {
        if (@bitSizeOf(Desc) != 16 * 8) @compileError("Desc size must be 16 bytes");
    }
};

/// Buffer descriptor for virtqueue operations.
pub const Buffer = struct {
    /// Physical address of the buffer.
    addr: u64,
    /// Length in bytes of the buffer.
    len: u32,
    /// True if device writes to this buffer.
    write: bool,
};

/// Used ring element.
pub const UsedElem = extern struct {
    /// Index of start of used descriptor chain.
    id: u32,
    /// Total length of the descriptor chain written to.
    len: u32,
};

/// Virtqueue abstraction.
pub const Virtqueue = struct {
    /// Available ring base.
    avail_base: usize,
    /// Used ring base.
    used_base: usize,
    /// Queue size.
    size: u16,
    /// Number of free descriptors.
    num_free: u16,
    /// Index of next free descriptor.
    free_head: u16,
    /// Last seen used index.
    last_used_idx: u16,

    /// Descriptor table.
    descs: [*]volatile Desc,
    /// Backing memory (physically contiguous).
    memory: []u8,

    /// Create a new virtqueue.
    pub fn create(size: u16, allocator: Allocator, page_allocator: PageAllocator) Error!*Virtqueue {
        // Calculate memory requirements.
        const desc_size = @sizeOf(Desc) * size;
        const avail_size = @sizeOf(u16) * 3 + @sizeOf(u16) * size; // flags + idx + ring + used_event
        const used_size = @sizeOf(u16) * 3 + @sizeOf(UsedElem) * size; // flags + idx + ring + avail_event

        // Align used ring to page boundary.
        const avail_offset = desc_size;
        const used_offset = std.mem.alignForward(
            usize,
            avail_offset + avail_size,
            page_size,
        );
        const total_size = std.mem.alignForward(
            usize,
            used_offset + used_size,
            page_size,
        );

        // Allocate contiguous memory.
        const memory = page_allocator.allocBytesV(total_size) catch return Error.OutOfMemory;
        errdefer page_allocator.freeBytesV(memory);
        @memset(memory, 0);

        const base_addr = @intFromPtr(memory.ptr);
        const descs: [*]volatile Desc = @ptrFromInt(base_addr);

        // Initialize free descriptor chain.
        for (0..size) |i| {
            descs[i].next = @intCast(i + 1);
        }

        const vq = allocator.create(Virtqueue) catch {
            return Error.OutOfMemory;
        };
        vq.* = .{
            .descs = descs,
            .avail_base = base_addr + avail_offset,
            .used_base = base_addr + used_offset,
            .size = size,
            .num_free = size,
            .free_head = 0,
            .last_used_idx = 0,
            .memory = memory,
        };

        return vq;
    }

    /// Destroy the virtqueue.
    pub fn destroy(self: *Virtqueue, page_allocator: PageAllocator, allocator: Allocator) void {
        page_allocator.freeBytesV(self.memory);
        allocator.destroy(self);
    }

    /// Get virtual address of descriptor table.
    pub fn getDescAddr(self: *const Virtqueue) u64 {
        return @intFromPtr(self.descs);
    }

    /// Get virtual address of available ring.
    pub fn getAvailAddr(self: *const Virtqueue) u64 {
        return self.avail_base;
    }

    /// Get virtual address of used ring.
    pub fn getUsedAddr(self: *const Virtqueue) u64 {
        return self.used_base;
    }

    /// Add a buffer chain to the queue.
    ///
    /// Returns the head descriptor index.
    pub fn addBuf(self: *Virtqueue, bufs: []const Buffer) Error!void {
        if (bufs.len == 0) {
            return Error.InvalidArgument;
        }
        if (self.num_free < bufs.len) {
            return Error.QueueFull;
        }

        const head = self.free_head;
        var idx = self.free_head;

        for (bufs, 0..) |buf, i| {
            self.descs[idx].addr = buf.addr;
            self.descs[idx].len = buf.len;
            self.descs[idx].flags = .{
                .write = buf.write,
                .next = i + 1 < bufs.len,
            };

            idx = self.descs[idx].next;
        }

        self.free_head = idx;
        self.num_free -= @intCast(bufs.len);

        // Add to available ring.
        const avail_idx_ptr: *volatile u16 = @ptrFromInt(self.avail_base + 2);
        const avail_ring_ptr: [*]volatile u16 = @ptrFromInt(self.avail_base + 4);
        const avail_idx = avail_idx_ptr.*;

        avail_ring_ptr[avail_idx % self.size] = head;
        avail_idx_ptr.* = avail_idx +% 1;
        arch.barrier(.full, .release);
    }

    /// Get a completed buffer from the used ring.
    ///
    /// Returns the head descriptor index and the length written.
    pub fn getUsed(self: *Virtqueue) ?struct { u16, u32 } {
        arch.barrier(.full, .acquire);

        const used_idx_ptr: *volatile u16 = @ptrFromInt(self.used_base + 2);
        const used_ring_ptr: [*]volatile UsedElem = @ptrFromInt(self.used_base + 4);

        if (self.last_used_idx == used_idx_ptr.*) {
            return null;
        }

        const elem = used_ring_ptr[self.last_used_idx % self.size];
        self.last_used_idx +%= 1;

        // Free the descriptor chain.
        var desc_idx: u16 = @intCast(elem.id);
        var count: u16 = 0;
        while (true) {
            count += 1;
            const next = self.descs[desc_idx].next;
            if (!self.descs[desc_idx].flags.next) {
                self.descs[desc_idx].next = self.free_head;
                self.free_head = @intCast(elem.id);
                break;
            }
            desc_idx = next;
        }
        self.num_free += count;

        return .{ @intCast(elem.id), elem.len };
    }
};

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
    _rsvd1: u2 = 0,
    /// Device has experienced an error from which it can't recover.
    device_needs_reset: bool,
    /// Something went wrong in the guest.
    failed: bool,
    /// Reserved.
    _rsvd2: u24 = 0,
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
const log = std.log.scoped(.virtio);
const Allocator = std.mem.Allocator;
const arch = @import("arch").impl;
const common = @import("common");
const bits = common.bits;
const mmio = common.mmio;
const PageAllocator = common.mem.PageAllocator;
