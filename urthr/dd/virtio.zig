//! Virtio device driver.
//!
//! - ref. Virtual I/O Device (VIRTIO) Version 1.3

/// MMIO transport.
pub const mmio = @import("virtio/mmio.zig");
/// PCI transport.
pub const pci = @import("virtio/pci.zig");

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

/// Transport-agnostic handle.
pub const Device = struct {
    /// Pointer to the transport-specific device instance.
    ptr: *anyopaque,
    /// Transport-agnostic operations.
    vtable: *const Vtable,

    pub const Vtable = struct {
        /// Setup a virtqueue indexed by `index`.
        setupQueue: *const fn (ptr: *anyopaque, index: u32) Error!void,
        /// Get a virtqueue by index.
        getQueue: *const fn (ptr: *anyopaque, index: u32) ?*Virtqueue,
        /// Notify the device that new there're new buffers in the virtqueue.
        notifyQueue: *const fn (ptr: *anyopaque, index: u16) void,
        /// Notify the device that driver is ready.
        finishInit: *const fn (ptr: *anyopaque) void,
        /// Read bytes from the device config space at the given `offset`.
        readConfigBytes: *const fn (ptr: *anyopaque, offset: usize, buf: []u8) void,
    };

    /// Setup a virtqueue indexed by `index`.
    pub fn setupQueue(self: Device, index: u32) Error!void {
        return self.vtable.setupQueue(self.ptr, index);
    }

    /// Get a virtqueue by index.
    pub fn getQueue(self: Device, index: u32) ?*Virtqueue {
        return self.vtable.getQueue(self.ptr, index);
    }

    /// Notify the device that new there're new buffers in the virtqueue.
    pub fn notifyQueue(self: Device, index: u16) void {
        self.vtable.notifyQueue(self.ptr, index);
    }

    /// Notify the device that driver is ready.
    pub fn finishInit(self: Device) void {
        self.vtable.finishInit(self.ptr);
    }

    /// Read a value from the device config space.
    ///
    /// Caller must ensure that `offset` is naturally aligned for type `T`.
    pub fn readConfig(self: Device, comptime T: type, offset: usize) T {
        var buf: [@sizeOf(T)]u8 align(@alignOf(T)) = undefined;
        self.vtable.readConfigBytes(self.ptr, offset, &buf);
        return @bitCast(buf);
    }
};

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

/// Page size for virtqueue alignment.
pub const page_size = 4096;

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
        _3: u13 = 0,
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
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const arch = @import("arch").impl;
const common = @import("common");
const PageAllocator = common.mem.PageAllocator;
