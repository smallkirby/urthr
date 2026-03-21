//! Cadence Gigabit Ethernet MAC (GEM_GXL 1p09)

// =============================================================
// Module Definition
// =============================================================

const gem = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x0000, Ncr },
    .{ 0x0004, Ncfgr },
    .{ 0x0008, Nsr },
    .{ 0x0010, Dmacfg },
    .{ 0x0014, Tsr },
    .{ 0x0018, Rxbqb },
    .{ 0x001C, Txbqb },
    .{ 0x0020, Rsr },
    .{ 0x0024, Isr },
    .{ 0x0028, Ier },
    .{ 0x002C, Idr },
    .{ 0x0030, Imr },
    .{ 0x0034, Man },
    .{ 0x0088, Sa1b },
    .{ 0x008C, Sa1t },
    .{ 0x00C0, Usrio },
    .{ 0x00FC, Mid },
    .{ 0x0108, Txcnt },
    .{ 0x0158, Rxcnt },
    .{ 0x0280, Dconfig1 },
    .{ 0x0400, mmio.Marker(.isr) },
    .{ 0x04C8, Txbqbh },
    .{ 0x04D4, Rxbqbh },
    .{ 0x0600, mmio.Marker(.ier) },
    .{ 0x0620, mmio.Marker(.idr) },
    .{ 0x0640, mmio.Marker(.imr) },
});

const Self = @This();

/// MMIO register module.
module: gem,
/// DMA allocator for managing DMA-capable memory.
dma_allocator: DmaAllocator,
/// RX queue.
rxq: RxQueue = undefined,
/// TX queue.
txq: TxQueue = undefined,

/// Queue index for RX.
const rxq_idx = 0;
/// Queue index for TX.
const txq_idx = 1;

/// Maximum Transmission Unit in bytes.
pub const mtu = 1500;
/// Maximum Transmission Unit in bytes including header.
pub const mtu_all = mtu + 14; // + Ethernet header

/// Create a new network device for GEM controller.
///
/// Memory allocated for this driver will be managed by the given memory manager.
pub fn new(base: usize, mac: MacAddr, allocator: Allocator, dma: DmaAllocator) Allocator.Error!*net.Device {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    const netdev = try allocator.create(net.Device);
    errdefer allocator.destroy(netdev);

    self.* = .{
        .module = gem.new(base),
        .dma_allocator = dma,
    };

    netdev.* = .{
        .ctx = @ptrCast(self),
        .vtable = vtable,
        .flags = .{ .up = false },
        .mtu = mtu_all,
        .dev_type = .ether,
        .addr = undefined,
        .addr_len = MacAddr.length,
    };
    @memcpy(netdev.addr[0..MacAddr.length], &mac.value);

    return netdev;
}

/// Initialize PHY and GEM controller.
pub fn init(netdev: *net.Device) net.Error!void {
    const self: *Self = @ptrCast(@alignCast(netdev.ctx));

    if (self.module.read(Mid).idnum < 2) {
        @panic("The macb device is not GEM.");
    }

    // Select RGMII mode.
    self.module.write(Usrio, Usrio{
        .rgmii = true,
        .clken = true,
    });

    // Enable MDIO.
    self.module.write(Ncr, std.mem.zeroInit(Ncr, .{
        .mpe = true,
    }));
    self.module.modify(Ncfgr, .{
        .clk = 6, // div by 128
    });

    // Check PHY ID.
    log.info("PHY ID: {X:0>4}-{X:0>4}", .{
        self.mdioRead(2),
        self.mdioRead(3),
    });
    if (self.mdioRead(2) == 0xFFFF or self.mdioRead(3) == 0xFFFF) {
        @panic("No PHY detected.");
    }

    // Software reset.
    self.mdioWrite(0, 0x8000);

    // Wait for reset to complete.
    var timer = arch.timer.createTimer();
    timer.start(.sec(1));
    while (self.mdioRead(0) & 0x8000 != 0) {
        if (timer.expired()) {
            @panic("PHY reset timed out.");
        }
        std.atomic.spinLoopHint();
    }

    // Initialize MAC address.
    var mac = self.getMacAddr();
    log.debug("Initial MAC address: {f}", .{mac});
    self.setMacAddr(.from(netdev.getAddr()));
    mac = self.getMacAddr();
    log.info("MAC address set to: {f}", .{mac});

    // Auto negotiation and wait for link up.
    const link = self.linkUp(.sec(5));
    arch.timer.spinWaitMilli(500);
    log.info("Link is up - 1Gbps / {s} duplex", .{if (link.full_duplex) "Full" else "Half"});

    // Configure NCFGR.
    rtt.expectEqual(4, self.module.read(Dconfig1).dbwdef);
    self.module.modify(Ncfgr, .{
        .spd = false,
        .gbe = true,
        .fd = link.full_duplex,
        .caf = false,
        .dbw = 2,
    });

    // Configure DMA.
    self.configureDma() catch |err| {
        log.err("Failed to configure GEM DMA: {}", .{err});
        return;
    };

    // Disable all interrupts first.
    self.setEnableIrq(rxq_idx, false);

    // Clear any pending interrupt status.
    _ = self.readClearIrq(rxq_idx);

    // Enable required interrupts.
    self.setEnableIrq(rxq_idx, true);

    // Enable RX and TX.
    self.module.modify(Ncr, .{
        .re = true,
        .te = true,
    });
}

const LinkInfo = struct {
    /// Link is full duplex.
    full_duplex: bool,
};

// Auto negotiation and wait for link up.
fn linkUp(self: *const Self, timeout: Timer.TimeSlice) LinkInfo {
    self.mdioWrite(4, 0x01E1);
    self.mdioWrite(0, 0x1200);

    var timer = arch.timer.createTimer();
    timer.start(timeout);

    var ok_count: usize = 0;
    while (true) {
        const bmsr: Bmsr = @bitCast(self.mdioRead(1));
        if (bmsr.auto_nego_complete and bmsr.link_status) {
            ok_count += 1;
            break;
        }

        if (ok_count >= 2) {
            break;
        }

        if (timer.expired()) {
            @panic("PHY link up timed out.");
        }

        arch.timer.spinWaitMicro(100);
    }

    const lpa: Stat1000 = @bitCast(self.mdioRead(0xA));
    return LinkInfo{
        .full_duplex = lpa.fd,
    };
}

/// Read the MAC address from the GEM controller.
fn getMacAddr(self: *const Self) MacAddr {
    const sa1b = self.module.read(Sa1b);
    const sa1t = self.module.read(Sa1t);

    return MacAddr{
        .value = [_]u8{
            sa1b.mac0,
            sa1b.mac1,
            sa1b.mac2,
            sa1b.mac3,
            sa1t.mac4,
            sa1t.mac5,
        },
    };
}

/// Set the MAC address in the GEM controller.
fn setMacAddr(self: *const Self, mac: MacAddr) void {
    self.module.write(Sa1b, Sa1b{
        .mac0 = mac.value[0],
        .mac1 = mac.value[1],
        .mac2 = mac.value[2],
        .mac3 = mac.value[3],
    });
    self.module.write(Sa1t, Sa1t{
        .mac4 = mac.value[4],
        .mac5 = mac.value[5],
    });
}

/// Enable or disable IRQ for a specific queue.
fn setEnableIrq(self: *const Self, qidx: usize, enable: bool) void {
    rtt.expect(qidx == 0); // Only one queue supported.

    if (enable) {
        self.module.write(Ier, std.mem.zeroInit(InterruptBf, .{
            .rcomp = true,
            .rxubr = true,
        }));
    } else {
        self.module.write(Idr, 0xFFFF_FFFF);
    }
}

/// Read and clear interrupt status register.
fn readClearIrq(self: *const Self, qidx: usize) InterruptBf {
    rtt.expect(qidx == 0); // Only one queue supported.

    const status = self.module.read(Isr);
    self.module.write(Isr, status);

    return status.value;
}

// =============================================================
// DMA
// =============================================================

/// RX Queue structure.
const RxQueue = struct {
    /// DMA-capable memory for RX descriptor queue.
    memory: []u8,
    /// List of bus address of RX buffer.
    buffers: [num_desc]DmaAllocator.BusAddress,
    /// Next descriptor index to start searching for received packets.
    next_idx: usize = 0,
    /// Tracks descriptors that have been acquired but not yet released.
    in_flights: std.StaticBitSet(num_desc) = std.StaticBitSet(num_desc).initEmpty(),

    /// DMA allocator that manages the memory.
    allocator: DmaAllocator,

    /// Number of descriptors.
    pub const num_desc = buffer_size / @sizeOf(Desc);
    /// RX buffer size
    const buffer_size = 2048;

    /// RX descriptor for 64-bit addressing.
    const Desc = packed struct(u128) {
        /// Buffer address (lower 32 bits).
        addr_lo: u32,
        /// Control and status.
        ctrl_stat: Control,
        /// Buffer address (upper 32 bits).
        addr_hi: u32,
        /// Reserved.
        _96: u32 = 0,

        /// Check if the descriptor is owned by software.
        pub fn swOwns(self: *const volatile Desc) bool {
            return bits.isset(self.addr_lo, 0);
        }

        /// Check if this is the last descriptor in the ring.
        pub fn isLast(self: *const volatile Desc) bool {
            return bits.isset(self.addr_lo, 1);
        }

        /// Set the buffer address (64-bit).
        fn setAddr(self: *volatile Desc, addr: u64) void {
            self.addr_lo = @truncate(addr);
            self.addr_hi = @truncate(addr >> 32);
        }

        /// Mark the descriptor as owned by software.
        fn setSwOwn(self: *volatile Desc) void {
            self.addr_lo = bits.set(self.addr_lo, 0);
        }

        /// Mark the descriptor as owned by hardware.
        fn setHwOwn(self: *volatile Desc) void {
            self.addr_lo = bits.unset(self.addr_lo, 0);
        }

        /// Mark this descriptor as the last in the ring.
        fn setWrap(self: *volatile Desc) void {
            self.addr_lo = bits.set(self.addr_lo, 1);
        }
    };

    /// RX control and status register.
    const Control = packed struct(u32) {
        /// Frame length.
        frmlen: u12,
        offset: u2,
        /// Start of frame.
        sof: bool,
        /// End of frame.
        eof: bool,
        cfi: bool,
        vlan_pri: u3,
        pri_tag: bool,
        vlan_tag: bool,
        typeid_match: bool,
        sa4_match: bool,
        sa3_match: bool,
        sa2_match: bool,
        sa1_match: bool,
        _27: u1 = 0,
        ext_match: bool,
        uhash_match: bool,
        mhash_match: bool,
        broadcast_match: bool,
    };

    /// Create a new RX queue.
    pub fn create(allocator: DmaAllocator) DmaAllocator.Error!RxQueue {
        const memory = try allocator.allocBytesV(@sizeOf(Desc) * num_desc);
        errdefer allocator.freeBytesV(memory);

        return .{
            .memory = memory,
            .buffers = undefined,
            .allocator = allocator,
        };
    }

    /// Initialize the RX queue.
    pub fn init(self: *RxQueue) DmaAllocator.Error!void {
        const descs = self.getDescs();
        for (descs[0..], 0..) |*desc, i| {
            const buffer = try self.createBuffer();
            self.buffers[i] = buffer;

            desc._96 = 0;
            desc.setAddr(buffer.addr);
            desc.setHwOwn();
            if (i == num_desc - 1) {
                desc.setWrap();
            }

            desc.ctrl_stat = std.mem.zeroInit(Control, .{});
        }

        arch.cache(.clean, self.memory, self.memory.len);
    }

    /// Invalidate cache for RX descriptors.
    pub fn invalidateCache(self: *const RxQueue) void {
        arch.cache(.invalidate, self.memory.ptr, self.memory.len);
    }

    /// Flush cache for RX descriptors.
    pub fn flushCache(self: *const RxQueue) void {
        arch.cache(.clean, self.memory.ptr, self.memory.len);
    }

    /// Get a RX buffer if it has been consumed by MAC.
    ///
    /// The descriptor is still owned by SW after this call.
    /// Returns null if the buffer is still owned by MAC or already acquired.
    fn tryAcquireBuffer(self: *RxQueue, index: usize) ?[]const u8 {
        const desc = &self.getDescs()[index];

        if (!self.in_flights.isSet(index) and desc.swOwns()) {
            const ptr = self.allocator.translateV(self.buffers[index], [*]const u8);
            const len = desc.ctrl_stat.frmlen;
            arch.cache(.invalidate, ptr, len);

            self.in_flights.set(index);
            return ptr[0..len];
        } else {
            return null;
        }
    }

    /// Find and acquire the next received packet if available.
    ///
    /// Returns a descriptor referencing the received buffer data.
    /// The descriptor remains owned by software until `releaseRxBuf` is called.
    /// Returns null if no packet is available in the queue.
    pub fn tryAcquireRx(self: *RxQueue) ?net.Device.PollResult {
        arch.cache(.invalidate, self.memory.ptr, self.memory.len);

        for (0..num_desc) |i| {
            const idx = (self.next_idx + i) % num_desc;
            if (self.tryAcquireBuffer(idx)) |data| {
                self.next_idx = (idx + 1) % num_desc;
                return .{
                    .data = data,
                    .handle = idx,
                };
            }
        } else return null;
    }

    /// Release an RX descriptor back to the hardware.
    pub fn releaseRxBuf(self: *RxQueue, index: usize) void {
        const desc = &self.getDescs()[index];
        desc.setHwOwn();
        arch.cache(.clean, desc, @sizeOf(Desc));
        self.in_flights.unset(index);
    }

    /// Get the DMA address of the RX queue.
    pub fn addrDma(self: *const RxQueue) usize {
        return self.allocator.translateB(self.memory).addr;
    }

    /// Create a buffer for receiving packets.
    ///
    /// Returns the bus address of the buffer.
    fn createBuffer(self: *const RxQueue) DmaAllocator.Error!DmaAllocator.BusAddress {
        const page = try self.allocator.allocBytesB(buffer_size);
        arch.cache(
            .invalidate,
            self.allocator.translateV(page, usize),
            buffer_size,
        );
        return page;
    }

    /// Get the pointer to the RX descriptors.
    fn getDescs(self: *const RxQueue) *volatile [num_desc]Desc {
        return @ptrCast(@alignCast(self.memory.ptr));
    }
};

/// TX Queue structure.
const TxQueue = struct {
    /// DMA-capable memory for TX descriptor ring.
    memory: []u8,
    /// DMA-capable memory for TX data buffers.
    buffer_memory: []u8,
    /// Next descriptor index to use.
    next_idx: usize = 0,
    /// DMA allocator that manages the memory.
    allocator: DmaAllocator,

    /// Number of descriptors.
    const num_desc = 16;
    /// TX buffer size.
    const buffer_size = 2048;

    comptime {
        urd.comptimeAssert(buffer_size >= mtu_all, "TX buffer too small: ", .{buffer_size});
    }

    /// TX descriptor for 64-bit addressing.
    const Desc = packed struct(u128) {
        /// Buffer address (lower 32 bits).
        addr_lo: u32,
        /// Control and status.
        ctrl: Control,
        /// Buffer address (upper 32 bits).
        addr_hi: u32,
        /// Reserved.
        _96: u32 = 0,
    };

    /// TX control register.
    const Control = packed struct(u32) {
        /// Buffer length.
        length: u14,
        /// Reserved.
        _14: u1 = 0,
        /// Last buffer of frame.
        last: bool,
        /// Reserved.
        _16: u14 = 0,
        /// Wrap.
        wrap: bool,
        /// Used.
        used: bool,
    };

    /// Create a new TX queue, allocating DMA memory.
    pub fn create(allocator: DmaAllocator) DmaAllocator.Error!TxQueue {
        const desc_mem = try allocator.allocBytesV(@sizeOf(Desc) * num_desc);
        errdefer allocator.freeBytesV(desc_mem);

        const buf_mem = try allocator.allocBytesV(buffer_size * num_desc);
        errdefer allocator.freeBytesV(buf_mem);

        return .{
            .memory = desc_mem,
            .buffer_memory = buf_mem,
            .allocator = allocator,
        };
    }

    /// Initialize all TX descriptors as used.
    pub fn init(self: *TxQueue) void {
        const descs = self.getDescs();
        for (descs[0..], 0..) |*desc, i| {
            const buf_addr = self.getBufferBusAddr(i);
            desc.addr_lo = @truncate(buf_addr);
            desc.addr_hi = @truncate(buf_addr >> 32);
            desc._96 = 0;
            desc.ctrl = .{
                .length = 0,
                .last = false,
                .wrap = i == num_desc - 1,
                .used = true,
            };
        }

        arch.cache(.clean, self.memory.ptr, self.memory.len);
    }

    /// Copy frame data into the TX buffer and set up the descriptor.
    pub fn prepareFrame(self: *TxQueue, data: []const u8) void {
        const idx = self.next_idx;
        self.next_idx = (idx + 1) % num_desc;

        const buf = self.getBufferVirtPtr(idx);
        @memcpy(buf[0..data.len], data);
        arch.cache(.clean, buf, data.len);

        const desc = &self.getDescs()[idx];
        desc.ctrl = .{
            .length = @intCast(data.len),
            .last = true,
            .wrap = idx == num_desc - 1,
            .used = false,
        };
        arch.cache(.clean, desc, @sizeOf(Desc));
    }

    /// Poll until any descriptor's used bit is set by HW.
    ///
    /// Returns error.Timeout after timeout.
    pub fn waitForCompletion(self: *const TxQueue, timeout: Timer.TimeSlice) net.Error!void {
        const idx = self.next_idx;
        const desc = &self.getDescs()[idx];

        var timer = arch.timer.createTimer();
        timer.start(timeout);

        while (true) {
            arch.cache(.invalidate, desc, @sizeOf(Desc));
            if (desc.ctrl.used) return;

            if (timer.expired()) return net.Error.Timeout;

            std.atomic.spinLoopHint();
        }
    }

    /// Get the DMA bus address of the descriptor ring.
    pub fn addrDma(self: *const TxQueue) usize {
        return self.allocator.translateB(self.memory).addr;
    }

    /// Get the bus address of a specific TX buffer.
    fn getBufferBusAddr(self: *const TxQueue, idx: usize) usize {
        const base = self.allocator.translateB(self.buffer_memory).addr;
        return base + idx * buffer_size;
    }

    /// Get a virtual pointer to a specific TX buffer.
    fn getBufferVirtPtr(self: *const TxQueue, idx: usize) [*]u8 {
        return self.buffer_memory.ptr + idx * buffer_size;
    }

    /// Get the pointer to the TX descriptors.
    fn getDescs(self: *const TxQueue) *volatile [num_desc]Desc {
        return @ptrCast(@alignCast(self.memory.ptr));
    }
};

/// Configure DMA settings.
fn configureDma(self: *Self) DmaAllocator.Error!void {
    // Configure DMA settings.
    self.module.write(Dmacfg, std.mem.zeroInit(Dmacfg, .{
        .fbldo = 16, // 16 beats
        .endia_desc = builtin.cpu.arch.endian() == .big,
        .endia_pkt = builtin.cpu.arch.endian() == .big,
        .rxbms = 3, // Full RX packet buffer
        .txpbms = true, // Full TX packet buffer
        .rxbs = 32, // 2048 bytes
        .addr64 = true, // Enable 64-bit DMA addressing
    }));

    // Allocate and configure RX queue.
    self.rxq = try RxQueue.create(self.dma_allocator);
    try self.rxq.init();

    // Set RX queue address.
    const rxq_dma = self.rxq.addrDma();
    self.module.write(Rxbqbh, @as(u32, @truncate(rxq_dma >> 32)));
    self.module.write(Rxbqb, @as(u32, @truncate(rxq_dma)));

    // Allocate and configure TX queue.
    self.txq = try TxQueue.create(self.dma_allocator);
    self.txq.init();

    // Set TX queue address.
    const txq_dma = self.txq.addrDma();
    self.module.write(Txbqbh, @as(u32, @truncate(txq_dma >> 32)));
    self.module.write(Txbqb, @as(u32, @truncate(txq_dma)));

    arch.barrier(.full, .release);
}

/// Get the next received packet if available.
///
/// Calling this function clears the IRQ status for RX.
pub fn tryGetRx(self: *Self) ?net.Device.PollResult {
    _ = self.readClearIrq(rxq_idx);

    return self.rxq.tryAcquireRx();
}

// =============================================================
// MDIO
// =============================================================

/// PHY address.
const phy_addr = 1;

/// Read a PHY register at a specific PHY address.
fn mdioReadAddr(self: *const Self, phy: u5, reg: u5) u16 {
    self.mdioWaitForIdle();

    self.module.write(Man, Man{
        .sof = 0b01, // Clause 22
        .rw = .read,
        .phya = phy,
        .rega = reg,
        .code = 0b10,
        .data = 0,
    });

    self.mdioWaitForIdle();

    return self.module.read(Man).data;
}

/// Read a PHY register.
fn mdioRead(self: *const Self, reg: u5) u16 {
    return self.mdioReadAddr(phy_addr, reg);
}

/// Write to a PHY register.
fn mdioWrite(self: *const Self, reg: u5, value: u16) void {
    self.mdioWaitForIdle();

    self.module.write(Man, Man{
        .sof = 0b01, // Clause 22
        .rw = .write,
        .phya = phy_addr,
        .rega = reg,
        .code = 0b10,
        .data = value,
    });

    self.mdioWaitForIdle();
}

/// Wait for the MDIO operation to complete.
fn mdioWaitForIdle(self: *const Self) void {
    var timer = arch.timer.createTimer();
    timer.start(.ms(10));

    while (self.module.read(Nsr).idle == false) {
        if (timer.expired()) {
            @panic("GEM MDIO operation timed out.");
        }

        std.atomic.spinLoopHint();
    }
}

/// 0x00: Basic Mode Control Register.
const Bmcr = packed struct(u16) {
    /// Reserved.
    _0: u7 = 0,
    /// Collision test enable.
    collision_test: bool,
    /// Full duplex.
    full_duplex: bool,
    /// Restart auto-negotiation.
    restart_auto_nego: bool,
    /// Isolate.
    isolate: bool,
    /// Power Down.
    power_down: bool,
    /// Auto-Negotiation enable.
    auto_nego_enable: bool,
    /// Speed select.
    speed_select: enum(u1) {
        /// 10 Mb.
        mb10 = 0,
        /// 100 Mb.
        mb100 = 1,
    },
    /// Loopback.
    loopback: bool,
    /// Reset.
    reset: bool,
};

/// 0x01: Basic Mode Status Register.
const Bmsr = packed struct(u16) {
    /// Extended capability.
    ext_cap: bool,
    /// Jabber detected.
    jabber_det: bool,
    /// Link status.
    link_status: bool,
    /// Auto-Negotiation ability.
    auto_nego_ability: bool,
    /// Remote fault indication.
    remote_fault: bool,
    /// Auto-Negotiation complete.
    auto_nego_complete: bool,
    /// Preamble suppression Capable.
    mf_preamble_supp: bool,
    /// Reserved.
    _7: u4 = 0,
    /// 10BASE-T HALF DUPLEX.
    spd10baset_hd: bool,
    /// 10BASE-T FULL DUPLEX.
    spd10baset_fd: bool,
    /// 100BASE-TX HALF DUPLEX.
    spd100baset_hd: bool,
    /// 100BASE-TX FULL DUPLEX.
    spd100baset_fd: bool,
    /// 100BASE-T4.
    spd100baset4: bool,
};

/// 0x0A: 1000BASE-T Status Register.
const Stat1000 = packed struct(u16) {
    /// Reserved.
    _0: u10,
    /// Half duplex.
    hd: bool,
    /// Full duplex.
    fd: bool,
    /// Remote receiver status.
    remrxok: bool,
    /// Local receiver status.
    locrxok: bool,
    /// Master / Slave resolution status.
    msres: bool,
    /// Master / Slave resolution failure.
    msfail: bool,
};

// =============================================================
// Network Interface
// =============================================================

const vtable: net.Device.Vtable = .{
    .open = init,
    .output = outputImpl,
    .poll = pollImpl,
    .releaseRxBuf = releaseRxBufImpl,
};

fn pollImpl(dev: *net.Device) net.Error!?net.Device.PollResult {
    const self: *Self = @ptrCast(@alignCast(dev.ctx));
    return self.tryGetRx();
}

fn releaseRxBufImpl(dev: *net.Device, index: usize) void {
    const self: *Self = @ptrCast(@alignCast(dev.ctx));
    self.rxq.releaseRxBuf(index);
}

fn outputImpl(dev: *net.Device, _: net.Protocol, data: []const u8) net.Error!void {
    const self: *Self = @ptrCast(@alignCast(dev.ctx));

    if (data.len == 0 or data.len > mtu_all) {
        return net.Error.InvalidPacket;
    }

    // Prepare the frame in the TX buffer and descriptor.
    self.txq.prepareFrame(data);
    arch.barrier(.full, .release);

    // Start transmission and wait for completion.
    self.module.modify(Ncr, .{ .tstart = true });
    self.txq.waitForCompletion(.ms(10)) catch |err| {
        log.err("TX timeout on descriptor {}", .{self.txq.next_idx});
        return err;
    };
}

// =============================================================
// Registers
// =============================================================

/// Network Control Register.
const Ncr = packed struct(u32) {
    /// Reserved.
    lb: u1 = 0,
    /// Loop back local.
    llb: bool,
    /// Receive enable.
    re: bool,
    /// Transmit enable.
    te: bool,
    /// Management port enable.
    mpe: bool,
    /// Clear stats.
    clrstat: bool,
    /// Incremental stats.
    incstat: bool,
    /// Write enable stats.
    westat: bool,
    /// Back pressure.
    bp: bool,
    /// Start transmission.
    tstart: bool,
    /// Transmit halt.
    thalt: bool,
    /// Transmit pause frame.
    tpf: bool,
    /// Transmit zero quantum pause frame.
    tzq: bool,
    /// Reserved.
    _13: u2 = 0,
    /// Store Receive Timestamp to Memory.
    srtsm: bool,
    /// Reserved.
    _16: u4 = 0,
    /// PTP Unicast packet enable.
    ptpuni: bool,
    /// Reserved.
    _21: u3 = 0,
    /// Enable One Step Synchro Mode.
    ossmode: bool,
    /// Reserved.
    _25: u3 = 0,
    /// MII Usage on RGMII Interface.
    miionrgmii: bool,
    /// Reserved.
    _29: u2 = 0,
    ///
    enable_hs_mac: bool,
};

/// Network Configuration Register.
const Ncfgr = packed struct(u32) {
    /// Speed.
    spd: bool,
    /// Full duplex.
    fd: bool,
    /// Discard non-VLAN frames.
    bit_rate: bool,
    /// Reserved.
    jframe: bool,
    /// Copy all frames.
    caf: bool,
    /// No broadcast.
    nbc: bool,
    /// Multicast hash enable.
    mti: bool,
    /// Unicast hash enable.
    uni: bool,
    /// Receive 1536 byte frames.
    big: bool,
    /// External address match enable.
    eae: bool,
    /// Gigabit mode enable.
    gbe: bool,
    ///
    pcssel: bool,
    /// Retry test.
    rty: bool,
    /// Pause enable.
    pae: bool,
    /// Receive buffer offset
    rbof: u2,
    /// Length field error frame discard.
    rlce: bool,
    /// FCS remove.
    drfcs: bool,
    /// MDC clock division.
    clk: u3,
    /// Data bus width.
    dbw: u3,
    ///
    _24: u8 = 0,
};

/// Network Status Register.
const Nsr = packed struct(u32) {
    /// pcs_link_state.
    link: bool,
    /// Status of the mdio_in pin.
    mdio: bool,
    /// The PHY management logic is idle.
    idle: bool,
    /// Reserved.
    _3: u29 = 0,
};

/// User I/O Register.
const Usrio = packed struct(u32) {
    rgmii: bool,
    clken: bool,
    _2: u30 = 0,
};

/// DMA Configuration Register.
const Dmacfg = packed struct(u32) {
    /// Fixed burst length for DMA data operations.
    fbldo: u5,
    /// Reserved.
    _5: u1 = 0,
    /// Endian swap mode for management descriptor access.
    endia_desc: bool,
    /// Endian swap mode for packet data access.
    endia_pkt: bool,
    /// RX packet buffer memory size select.
    rxbms: u2,
    /// TX packet buffer memory size select.
    txpbms: bool,
    /// TX IP/TCP/UDP checksum gen offload.
    txcoen: bool,
    /// Reserved.
    _12: u4 = 0,
    /// DMA receive buffer size.
    rxbs: u8,
    /// disc_when_no_ahb
    ddrp: bool,
    /// Reserved.
    _25: u3 = 0,
    /// RX extended Buffer Descriptor mode.
    rxext: bool,
    /// TX extended Buffer Descriptor mode.
    txext: bool,
    /// Address bus 64 bits.
    addr64: bool,
    /// Reserved.
    _31: u1 = 0,
};

/// Receive Buffer Queue Base Address Register.
const Rxbqb = packed struct(u32) {
    addr: u32,
};

/// Transmit Buffer Queue Base Address Register.
const Txbqb = packed struct(u32) {
    addr: u32,
};

/// Transmit Buffer Queue Base Address High Register.
const Txbqbh = packed struct(u32) {
    addr: u32,
};

/// Receive Buffer Queue Base Address High Register.
const Rxbqbh = packed struct(u32) {
    addr: u32,
};

/// TX Status Register.
const Tsr = packed struct(u32) {
    /// Used bit read.
    ubr: bool,
    /// Collision occurred.
    col: bool,
    /// Retry limit exceeded.
    rle: bool,
    /// Transmit go.
    txgo: bool,
    /// Transmit frame corruption (AHB error).
    tfc: bool,
    /// Transmit complete.
    comp: bool,
    /// Reserved.
    _6: u2 = 0,
    /// HRESP not OK.
    hresp: bool,
    /// Reserved.
    _9: u23 = 0,
};

/// RX Status Register.
const Rsr = packed struct(u32) {
    /// Buffer not available.
    bna: bool,
    /// Frame received.
    received: bool,
    /// Overrun.
    overrun: bool,
    /// Reserved.
    _3: u29 = 0,
};

/// Bitfields for ISR, IER, IDR, and IMR registers.
const InterruptBf = packed struct(u32) {
    /// Management frame sent.
    mfs: bool,
    /// Receive complete.
    rcomp: bool,
    /// RX used bit read.
    rxubr: bool,
    /// TX used bit read.
    txubr: bool,
    /// TX buffer underrun.
    tund: bool,
    /// Retry limit exceeded.
    rlex: bool,
    /// TX frame corruption (AHB/AXI error).
    txerr: bool,
    /// Transmit complete.
    tcomp: bool,

    /// Reserved.
    _8: u1 = 0,
    /// Link change.
    link: bool,
    /// Receive overrun.
    rovr: bool,
    /// HRESP not OK.
    hresp: bool,
    /// Pause frame without quantum.
    pfr: bool,
    /// Pause time has reached zero.
    ptz: bool,
    /// Wake-on-LAN frame received.
    wol: bool,
    /// Reserved.
    _15: u1 = 0,

    /// Reserved.
    _16: u2 = 0,
    /// PTP Delay request frame received.
    drqfr: bool,
    /// PTP Sync frame received.
    sfr: bool,
    /// PTP Delay request frame transmitted.
    drqft: bool,
    /// PTP Sync frame transmitted.
    sft: bool,
    /// PDelay Request frame received.
    pdrqfr: bool,
    /// PDelay Response frame received.
    pdrsfr: bool,

    /// PDelay Request frame transmitted.
    pdrqft: bool,
    /// PDelay Response frame transmitted.
    pdrsft: bool,
    /// TSU seconds register increment.
    sri: bool,
    /// Reserved.
    _27: u1 = 0,
    /// Wake-on-LAN frame received.
    wol2: bool,
    /// Reserved.
    _29: u3 = 0,
};

/// Interrupt status register.
const Isr = packed struct {
    value: InterruptBf,
};

/// Interrupt enable register.
const Ier = packed struct {
    value: InterruptBf,
};

/// Interrupt disable register.
const Idr = packed struct {
    value: InterruptBf,
};

/// Interrupt mask register.
const Imr = packed struct {
    value: InterruptBf,
};

/// PHY Maintenance Register.
const Man = packed struct(u32) {
    /// Data.
    data: u16,
    /// Code.
    code: u2,
    /// Register address.
    rega: u5,
    /// PHY address.
    phya: u5,
    /// Operation.
    rw: enum(u2) {
        /// Read.
        read = 2,
        /// Write.
        write = 1,
    },
    /// Start of frame.
    sof: u2,
};

/// Specific Address 1 Bottom Register.
const Sa1b = packed struct(u32) {
    mac0: u8,
    mac1: u8,
    mac2: u8,
    mac3: u8,
};

/// Specific Address 1 Top Register.
const Sa1t = packed struct(u32) {
    mac4: u8,
    mac5: u8,
    _16: u16 = 0,
};

/// Identification Register.
const Mid = packed struct(u32) {
    rev: u16,
    idnum: u12,
    _28: u4,
};

/// Transmit Count Register.
const Txcnt = packed struct(u32) { value: u32 };

/// Receive Count Register.
const Rxcnt = packed struct(u32) { value: u32 };

/// Design Configuration 1 Register.
const Dconfig1 = packed struct(u32) {
    no_pcs: bool,
    _1: u22 = 0,
    irqcor: bool,
    _24: u1 = 0,
    dbwdef: u3,
    _28: u4 = 0,
};

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const std = @import("std");
const log = std.log.scoped(.gem);
const Allocator = std.mem.Allocator;
const common = @import("common");
const bits = common.bits;
const mmio = common.mmio;
const rtt = common.rtt;
const Timer = common.Timer;
const DmaAllocator = common.mem.DmaAllocator;
const MemoryManager = common.mem.MemoryManager;
const arch = @import("arch").impl;
const urd = @import("urthr");
const net = urd.net;
const MacAddr = net.ether.MacAddr;
