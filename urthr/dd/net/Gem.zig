//! Cadence Gigabit Ethernet MAC (GEM_GXL 1p09)

// =============================================================
// Module Definition
// =============================================================

const gem = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x0000, Ncr },
    .{ 0x0004, Ncfgr },
    .{ 0x0008, Nsr },
    .{ 0x0010, Dmacfg },
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

/// Queue index for RX.
const rxq_idx = 0;
/// Queue index for TX.
const txq_idx = 1;

/// MAC address type.
const MacAddr = [6]u8;

/// Default MAC address value.
const default_mac: MacAddr = [_]u8{ 0xB8, 0x27, 0xEB, 0x00, 0x00, 0x00 };

/// Create a new GEM instance.
///
/// Memory allocated for this driver will be managed by the given memory manager.
pub fn new(base: usize, dma_allocator: DmaAllocator) Self {
    var module = gem{};
    module.setBase(base);

    return .{
        .module = module,
        .dma_allocator = dma_allocator,
    };
}

/// Initialize PHY and GEM controller.
pub fn init(self: *Self) void {
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
    log.debug("Initial MAC address: {X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}", .{
        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
    });
    self.setMacAddr(default_mac);
    mac = self.getMacAddr();
    log.info("MAC address set to: {X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}", .{
        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
    });

    // Auto negotiation and wait for link up.
    self.mdioWrite(4, 0x01E1);
    self.mdioWrite(0, 0x1200);
    timer.start(.sec(5));
    while (true) {
        const bmsr: Bmsr = @bitCast(self.mdioRead(1));
        if (bmsr.auto_nego_complete and bmsr.link_status) {
            break;
        }

        if (timer.expired()) {
            @panic("PHY link up timed out.");
        }

        arch.timer.spinWaitMicro(100);
    }
    const lpa: Stat1000 = @bitCast(self.mdioRead(0xA));
    log.info("Link is up - 1Gbps / {s} duplex", .{if (lpa.fd) "Full" else "Half"});

    // Configure NCFGR.
    rtt.expectEqual(4, self.module.read(Dconfig1).dbwdef);
    self.module.modify(Ncfgr, .{
        .spd = false,
        .gbe = true,
        .fd = lpa.fd,
        .caf = true, // TODO: Promiscuous for now
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

    // Enable RX.
    self.module.modify(Ncr, .{
        .re = true,
    });
}

/// Read the MAC address from the GEM controller.
fn getMacAddr(self: *const Self) MacAddr {
    const sa1b = self.module.read(Sa1b);
    const sa1t = self.module.read(Sa1t);

    return [_]u8{
        sa1b.mac0,
        sa1b.mac1,
        sa1b.mac2,
        sa1b.mac3,
        sa1t.mac4,
        sa1t.mac5,
    };
}

/// Set the MAC address in the GEM controller.
fn setMacAddr(self: *const Self, mac: MacAddr) void {
    self.module.write(Sa1b, Sa1b{
        .mac0 = mac[0],
        .mac1 = mac[1],
        .mac2 = mac[2],
        .mac3 = mac[3],
    });
    self.module.write(Sa1t, Sa1t{
        .mac4 = mac[4],
        .mac5 = mac[5],
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
        _rsvd: u32 = 0,

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
        _rsvd0: u1 = 0,
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

            desc._rsvd = 0;
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
    /// Returns null if the buffer is still owned by MAC.
    pub fn tryAcquireBuffer(self: *const RxQueue, index: usize) ?[]const u8 {
        const desc = &self.getDescs()[index];

        if (desc.swOwns()) {
            const ptr = self.allocator.translateV(self.buffers[index], [*]const u8);
            const len = desc.ctrl_stat.frmlen;
            arch.cache(.invalidate, ptr, len);
            return ptr[0..len];
        } else {
            return null;
        }
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

    arch.barrier(.full, .release);
}

// =============================================================
// MDIO
// =============================================================

/// PHY address.
const phy_addr = 1;

/// Read a PHY register at a specific PHY address.
fn mdioReadAddr(self: *Self, phy: u5, reg: u5) u16 {
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
fn mdioRead(self: *Self, reg: u5) u16 {
    return self.mdioReadAddr(phy_addr, reg);
}

/// Write to a PHY register.
fn mdioWrite(self: *Self, reg: u5, value: u16) void {
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
fn mdioWaitForIdle(self: *Self) void {
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
    _rsvd: u7 = 0,
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
    _rsvd0: u4 = 0,
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
    _rsvd: u10,
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
// Interrupt Handling
// =============================================================

/// Handle interrupt from GEM controller.
pub fn handleInterrupt(self: *Self) void {
    const status = self.readClearIrq(rxq_idx);

    if (status.rcomp) {
        self.processRxPackets();
    }
}

/// Process received RX packets and return descriptors to HW.
fn processRxPackets(self: *Self) void {
    self.rxq.invalidateCache();

    const descs = self.rxq.getDescs();
    for (descs, 0..) |*desc, i| {
        if (self.rxq.tryAcquireBuffer(i)) |data| {
            // TODO: process received packet.
            log.debug("RXQ#{d} received packet:", .{i});
            common.util.hexdump(data, data.len, log.debug);

            // Return descriptor to HW.
            desc.setHwOwn();
        }
    }
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
    _0: u2 = 0,
    /// Store Receive Timestamp to Memory.
    srtsm: bool,
    /// Reserved.
    _1: u4 = 0,
    /// PTP Unicast packet enable.
    ptpuni: bool,
    /// Reserved.
    _2: u3 = 0,
    /// Enable One Step Synchro Mode.
    ossmode: bool,
    /// Reserved.
    _3: u3 = 0,
    /// MII Usage on RGMII Interface.
    miionrgmii: bool,
    /// Reserved.
    _4: u2 = 0,
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
    _1: u8 = 0,
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
    _0: u29 = 0,
};

/// User I/O Register.
const Usrio = packed struct(u32) {
    rgmii: bool,
    clken: bool,
    _rsvd: u30 = 0,
};

/// DMA Configuration Register.
const Dmacfg = packed struct(u32) {
    /// Fixed burst length for DMA data operations.
    fbldo: u5,
    /// Reserved.
    _rsvd0: u1 = 0,
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
    _rsvd1: u4 = 0,
    /// DMA receive buffer size.
    rxbs: u8,
    /// disc_when_no_ahb
    ddrp: bool,
    /// Reserved.
    _rsvd2: u3 = 0,
    /// RX extended Buffer Descriptor mode.
    rxext: bool,
    /// TX extended Buffer Descriptor mode.
    txext: bool,
    /// Address bus 64 bits.
    addr64: bool,
    /// Reserved.
    _rsvd3: u1 = 0,
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

/// RX Status Register.
const Rsr = packed struct(u32) {
    /// Buffer not available.
    bna: bool,
    /// Frame received.
    received: bool,
    /// Overrun.
    overrun: bool,
    /// Reserved.
    _rsvd: u29 = 0,
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
    _rsvd0: u1 = 0,
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
    _rsvd1: u1 = 0,

    /// Reserved.
    _rsvd2: u2 = 0,
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
    _rsvd3: u1 = 0,
    /// Wake-on-LAN frame received.
    wol2: bool,
    /// Reserved.
    _rsvd4: u3 = 0,
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
    _rsvd: u16 = 0,
};

/// Identification Register.
const Mid = packed struct(u32) {
    rev: u16,
    idnum: u12,
    _0: u4,
};

/// Receive Count Register.
const Rxcnt = packed struct(u32) { value: u32 };

/// Design Configuration 1 Register.
const Dconfig1 = packed struct(u32) {
    no_pcs: bool,
    _0: u22 = 0,
    irqcor: bool,
    _1: u1 = 0,
    dbwdef: u3,
    _2: u4 = 0,
};

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const std = @import("std");
const log = std.log.scoped(.gem);
const common = @import("common");
const bits = common.bits;
const mmio = common.mmio;
const rtt = common.rtt;
const Timer = common.Timer;
const DmaAllocator = common.mem.DmaAllocator;
const MemoryManager = common.mem.MemoryManager;
const arch = @import("arch").impl;
