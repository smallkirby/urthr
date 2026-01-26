//! Broadcom STB PCIe Controller for Raspberry Pi 5
//!
//! ref. https://github.com/raspberrypi/linux/blob/a1073743767f9e7fdc7017ababd2a07ea0c97c1c/drivers/pci/controller/pcie-brcmstb.c
//! ref. https://github.com/tnishinaga/pi5_hack/blob/653a12c40127ec2f9d6655336fb27b13090aab4c/baremetal/XX_pcie/src/bcm2712_pcie.rs

// =============================================================
// Module Definition
// =============================================================

/// STB module.
var pcie = mmio.Module(.{ .size = u32 }, &.{
    // =========================================================
    // Root Complex Configuration Space
    .{ 0x00AC, mmio.Marker(.cap_regs) },
    .{ 0x0A0C, RcTlVdmCtrl1 },
    .{ 0x0A20, RcTlVdmCtrl0 },
    .{ 0x0188, RcConfigVendorSpecific1 },
    .{ 0x043C, RcConfigPriv1Id3 },
    .{ 0x04DC, dd.pci.LinkCap1 },

    // =========================================================
    // MDIO etc.
    .{ 0x1100, RcDlMdioAddr },
    .{ 0x1104, RcDlMdioWrite },
    .{ 0x184C, RcPlPhyCtrl15 },

    // =========================================================
    // Misc Registers
    .{ 0x4008, MiscMiscCtrl },
    .{ 0x400C, MemWin0Low },
    .{ 0x4010, MemWin0High },
    .{ 0x402C, RcBar1ConfigLo },
    .{ 0x4030, RcBar1ConfigHi },
    .{ 0x40D4, RcBar4ConfigLo },
    .{ 0x40D8, RcBar4ConfigHi },
    .{ 0x405C, RcConfigRetryTimeout },
    .{ 0x4064, Control },
    .{ 0x4068, MiscStatus },
    .{ 0x4070, MemWin0BaseLimit },
    .{ 0x4080, MemWin0BaseHi },
    .{ 0x4084, MemWin0LimitHi },
    .{ 0x40A0, PcieCtrl },
    .{ 0x40A4, MiscUbusCtrl },
    .{ 0x40A8, MiscUbusTimeout },
    .{ 0x40AC, UbusBar1ConfigRemap },
    .{ 0x40B0, UbusBar1ConfigRemapHi },
    .{ 0x410C, UbusBar4ConfigRemap },
    .{ 0x4110, UbusBar4ConfigRemapHi },
    .{ 0x415C, MiscAxiIntfCtrl },
    .{ 0x4164, MiscVdmPriorityToQosMapHi },
    .{ 0x4168, MiscVdmPriorityToQosMapLo },
    .{ 0x4170, PcieMiscAxiReadErrorData },
    .{ 0x4304, HardDebug },

    // =========================================================
    // Configuration Space
    .{ 0x8000, mmio.Marker(.config_data) },
    .{ 0x9000, mmio.Marker(.config_address) },
}){};

/// Capability Structure module.
var capm = dd.pci.PcieCap{};

/// Offset added to AXI addresses to represent DMA addresses.
const dma_offset: usize = 0x10_0000_0000;

/// DMA allocator instance.
var dma_allocator: DmaAllocatorImpl = undefined;

// =============================================================
// API
// =============================================================

/// Set the base address of the PCIe controller.
pub fn setBase(base: usize) void {
    pcie.setBase(base);
}

/// Initialize the PCIe controller.
pub fn init(page_allocator: PageAllocator) void {
    // Set base address of PCIe Capability Structure.
    capm.setBase(pcie.getMarkerAddress(.cap_regs));

    // Reset controller.
    reset();

    // Initialize bridge settings.
    initBridge();

    // Disable PCIe -> GISB memory window.
    pcie.modifyIndexed(RcBar1ConfigLo, 0, 8, .{
        .size = 0,
    });
    // Disable PCIe -> SCB memory window.
    pcie.modifyIndexed(RcBar1ConfigLo, 2, 8, .{
        .size = 0,
    });

    // Instantiate DMA allocator.
    dma_allocator = DmaAllocatorImpl.new(page_allocator);
}

/// Setup outbound address translation.
pub fn setOutTranslation(axi: usize, pci: usize, size: usize, comptime win: usize) void {
    rtt.expectEqual(0, axi % units.mib);
    rtt.expectEqual(0, pci % units.mib);
    rtt.expectEqual(0, size % units.mib);

    const axi_base_mb = axi / units.mib;
    const axi_limit_mb = (axi + size - 1) / units.mib;

    // Set PCIe window.
    pcie.modifyIndexed(MemWin0Low, win, 8, .{
        .mem_win0_low = bits.extract(u32, pci, 0),
    });
    pcie.modifyIndexed(MemWin0High, win, 8, .{
        .mem_win0_high = bits.extract(u32, pci, 32),
    });

    // Set AXI window lower bits.
    pcie.modifyIndexed(MemWin0BaseLimit, win, 4, .{
        .mem_win0_base = bits.extract(u12, axi_base_mb, 0),
        .mem_win0_limit = bits.extract(u12, axi_limit_mb, 0),
    });

    // Set AXI window upper bits.
    pcie.modifyIndexed(MemWin0BaseHi, win, 8, .{
        .mem_win0_base_hi = bits.extract(u8, axi_base_mb, 12),
    });
    pcie.modifyIndexed(MemWin0LimitHi, win, 8, .{
        .mem_win0_limit_hi = bits.extract(u8, axi_limit_mb, 12),
    });
}

/// Setup inbound address translation.
pub fn setInTranslation(pci_addr: u64, cpu_addr: u64, size: u64, comptime bar: usize) void {
    const size_encoded = encodeIbarSize(size);

    // Configure RC BAR
    {
        const BarLow, const BarHigh, const idx = if (bar <= 3)
            .{ RcBar1ConfigLo, RcBar1ConfigHi, bar - 1 }
        else
            .{ RcBar4ConfigLo, RcBar4ConfigHi, bar - 4 };

        pcie.writeIndexed(BarLow, idx, 8, BarLow{
            .size = size_encoded,
            .pci_offset_lo = @intCast((pci_addr >> 12) & 0xFFFFF),
        });
        pcie.writeIndexed(BarHigh, idx, 8, BarHigh{
            .pci_offset_hi = @intCast(pci_addr >> 32),
        });
    }

    // Configure UBUS
    {
        const UbusLow, const UbusHigh, const idx = if (bar <= 3)
            .{ UbusBar1ConfigRemap, UbusBar1ConfigRemapHi, bar - 1 }
        else
            .{ UbusBar4ConfigRemap, UbusBar4ConfigRemapHi, bar - 4 };

        pcie.writeIndexed(UbusLow, idx, 8, UbusLow{
            .access_en = true,
            .cpu_addr_lo = @intCast((cpu_addr >> 12) & 0xFFFFF),
        });
        pcie.writeIndexed(UbusHigh, idx, 8, UbusHigh{
            .cpu_addr_hi = @intCast(cpu_addr >> 32),
        });
    }

    // Configure DMA
    pcie.modify(MiscMiscCtrl, .{
        .scb0_size = @as(u5, @intCast(size_encoded)),
    });
}

/// Convert the size of the inbound BAR region to the non-linear values.
fn encodeIbarSize(size: u64) u5 {
    const log2_size = std.math.log2(size);

    if (log2_size >= 12 and log2_size <= 15) {
        // Covers 4KB to 32KB
        return @intCast((log2_size - 12) + 0x1C);
    } else if (log2_size >= 16 and log2_size <= 37) {
        // Covers 64KB to 64GB
        return @intCast(log2_size - 15);
    }

    @panic("Invalid inbound BAR size");
}

/// Get the configuration space I/O interface for Type 0 headers.
pub fn getConfIoType0() dd.pci.ConfIo(dd.pci.HeaderType0) {
    return dd.pci.ConfIo(dd.pci.HeaderType0){ .method = .{ .brcm = .{
        .data_base = pcie.getMarkerAddress(.config_data),
        .address_base = pcie.getMarkerAddress(.config_address),
    } } };
}

/// Get the configuration space I/O interface for Type 1 headers.
pub fn getConfIoType1() dd.pci.ConfIo(dd.pci.HeaderType1) {
    return dd.pci.ConfIo(dd.pci.HeaderType1){ .method = .{ .brcm = .{
        .data_base = pcie.getMarkerAddress(.config_data),
        .address_base = pcie.getMarkerAddress(.config_address),
    } } };
}

/// Get the DMA allocator that can be used to transfer data over PCIe.
pub fn getDmaAllocator() DmaAllocator {
    return dma_allocator.interface();
}

/// Reset the PCIe controller.
fn reset() void {
    // Assert #PERST.
    pcie.modify(Control, .{ .perstb = 0 });
    arch.timer.spinWaitMicro(100);

    // Reset PHY.
    pcie.modify(HardDebug, .{ .serdes_iddq = 0 });
    arch.timer.spinWaitMicro(100);

    // Setup clock.
    mdioWrite(0x1F, 0x1600);
    mdioWrite(0x16, 0x50B9);
    mdioWrite(0x17, 0xBDA1);
    mdioWrite(0x18, 0x0094);
    mdioWrite(0x19, 0x97B4);
    mdioWrite(0x1B, 0x5030);
    mdioWrite(0x1C, 0x5030);
    mdioWrite(0x1E, 0x0007);
    arch.timer.spinWaitMicro(100);

    // Set L1SS sub-state timers to avoid lengthy state transitions.
    pcie.modify(RcPlPhyCtrl15, .{
        .pm_clk_period = 0x12, // PM clock period is 18.52 ns
        .pll_pd_disable = false,
    });

    // Suppress AXI error responses and return 1s for read failures.
    pcie.modify(MiscUbusCtrl, .{
        .reply_error_disable = true,
        .replay_dec_error_disable = true,
    });
    pcie.write(PcieMiscAxiReadErrorData, 0xFFFF_FFFF);

    // Adjust timeouts.
    pcie.write(MiscUbusTimeout, 0x0B2D_0000);
    pcie.write(RcConfigRetryTimeout, 0x0ABA_0000);

    // Disable broken forwarding search. Set chicken bits for 2712D0.
    pcie.modify(MiscAxiIntfCtrl, .{
        .reqfifo_en_qos_propagation = false,
        .en_rclk_qos_array_fix = true,
        .en_qos_update_timing_fix = true,
        .dis_qos_gating_in_master = true,
    });

    // Work around spurious QoS=0 assignments to inbound traffic.
    if (!pcie.read(MiscAxiIntfCtrl).en_qos_update_timing_fix) {
        var value: u32 = @bitCast(pcie.read(MiscAxiIntfCtrl));
        value &= ~@as(u32, 0x3F);
        value |= 15;
        pcie.write(MiscAxiIntfCtrl, value);
    }

    // Setup QoS.
    pcie.modify(PcieCtrl, .{
        .en_vdm_qos_control = true,
    });
    pcie.write(MiscVdmPriorityToQosMapHi, 0xBBAA9888);
    pcie.write(MiscVdmPriorityToQosMapLo, 0xBBAA9888);
    pcie.write(RcTlVdmCtrl1, 0);
    pcie.modify(RcTlVdmCtrl0, .{
        .enabled = true,
        .ignore_tag = true,
        .ignore_vendor_id = true,
    });

    // Setup Root Complex configuration.
    pcie.modify(RcConfigPriv1Id3, .{
        // PCI-to-PCI Bridge
        .interface = 0x00,
        .subclass = 0x04,
        .class = 0x06,
    });

    // PCIe->SCB endian mode for inbound window.
    pcie.modify(RcConfigVendorSpecific1, .{
        .endian = .little,
    });

    // Configure DMA.
    pcie.write(MiscMiscCtrl, std.mem.zeroInit(MiscMiscCtrl, .{
        .scb_access_en = true,
        .cfg_read_ur_mode = true,
        .max_burst_size = .b256,
    }));

    // Set link speed.
    pcie.modify(dd.pci.LinkCap1, .{
        .max_link_speed = dd.pci.LinkCap1.LinkSpeed.speed_5_0_gt,
    });
    capm.modify(dd.pci.LinkControlStatus2, .{
        .target_link_speed = dd.pci.LinkControlStatus2.LinkSpeed.speed_5_0_gt,
    });

    // De-assert #PERST.
    pcie.modify(Control, .{ .perstb = 1 });
    arch.timer.spinWaitMilli(100);

    // Wait for link up.
    for (0..10) |_| {
        const status = pcie.read(MiscStatus);
        if (status.link_up and status.dl_active) {
            break;
        }
        arch.timer.spinWaitMilli(100);
    } else {
        @panic("PCIe link up timeout");
    }
}

/// Initialize PCI-to-PCI bridge.
fn initBridge() void {
    var header = dd.pci.HeaderType1{};
    header.setBase(pcie.base);

    // Configure bridge's configuration space.
    header.modify(dd.pci.HeaderCommandStatus, .{
        .bus_master_enable = true,
        .memory_space_enable = true,
    });
    header.modify(dd.pci.HeaderBusNum, .{
        .primary_bus_number = 0,
        .secondary_bus_number = 1,
        .subordinate_bus_number = 1,
    });
    header.modify(dd.pci.HeaderMemBaseLimit, .{
        .mem_base = 0x0000_0000,
        .mem_limit = 0x0000_FFFF, // TODO: value chosen arbitrarily
    });
    header.modify(dd.pci.HeaderPrefMemBaseLimit, .{
        .pref_mem_base = 0x0000_0000,
        .pref_mem_limit = 0x0000_FFFF, // TODO: value chosen arbitrarily
    });

    // Init AER.
    initAer();
}

/// Initialize Advanced Error Reporting (AER).
fn initAer() void {
    var conf = dd.pci.HeaderType1{};
    conf.setBase(pcie.base);

    // Search for AER capability.
    const header = conf.read(dd.pci.ExtCapHeader);
    if (header.id != extcap_id_aer) {
        // TODO: iterate through extended capabilities.
        @panic("AER capability not found.");
    }

    var aer = Aer{};
    aer.setBase(conf.getRegisterAddress(dd.pci.ExtCapHeader));

    // Unmask all error reporting.
    aer.write(AerUncorrectableMask, 0);
    aer.write(AerCorrectableMask, 0);
}

/// AER status.
const AerStatus = struct {
    /// Correctable error status.
    correctable: AerCorrectableErr,
    /// Uncorrectable error status.
    uncorrectable: AerUncorrectableErr,
    /// Header logs.
    logs: [4]u32,
};

/// Get the PCIe uncorrectable and correctable error status.
pub fn getErrors() AerStatus {
    var conf = dd.pci.HeaderType1{};
    conf.setBase(pcie.base);

    var aer = Aer{};
    aer.setBase(conf.getRegisterAddress(dd.pci.ExtCapHeader));

    var ret: AerStatus = undefined;
    ret.correctable = aer.read(AerCorrectableErr);
    ret.uncorrectable = aer.read(AerUncorrectableErr);
    const logs: [*]const volatile u32 = @ptrFromInt(aer.getMarkerAddress(.log0));
    for (0..4) |i| {
        ret.logs[i] = logs[i];
    }

    return ret;
}

// =============================================================
// MDIO
// =============================================================

/// Issue a MDIO write command.
pub fn mdioWrite(addr: u16, data: u32) void {
    // Set write address.
    const mdio = MdioAddr{
        .addr = addr,
        .cmd = .write,
    };
    pcie.write(RcDlMdioAddr, mdio);
    rtt.expectEqual(mdio, pcie.read(RcDlMdioAddr));

    // Write data.
    const data_done_bit_pos = 31;
    pcie.write(RcDlMdioWrite, bits.set(data, data_done_bit_pos));

    // Wait for completion.
    for (0..10) |_| {
        if (bits.isset(pcie.read(RcDlMdioWrite).value, data_done_bit_pos)) {
            return;
        }
        std.atomic.spinLoopHint();
    }

    @panic("MDIO write timeout");
}

/// Target address of MDIO packets.
const MdioAddr = packed struct(u32) {
    /// Target address.
    addr: u16,
    /// Target port.
    port: u4 = 0,
    /// Command.
    cmd: Command,

    pub const Command = enum(u12) {
        read = 0,
        write = 1,
    };
};

// =============================================================
// DMA allocator
// =============================================================

const DmaAllocatorImpl = struct {
    const Self = @This();

    page_allocator: PageAllocator,

    const vtable = DmaAllocator.Vtable{
        .allocPages = Self.allocPages,
        .freePages = Self.freePages,
        .virt2phys = Self.virt2phys,
        .phys2virt = Self.phys2virt,
    };

    /// Create a new allocator implementing DmaAllocator interface.
    pub fn new(page_allocator: PageAllocator) Self {
        return .{ .page_allocator = page_allocator };
    }

    /// Get the DmaAllocator interface.
    pub fn interface(self: *Self) DmaAllocator {
        return DmaAllocator{
            .ptr = @ptrCast(self),
            .vtable = &Self.vtable,
            .offset = dma_offset,
        };
    }

    fn allocPages(ctx: *anyopaque, num_pages: usize) DmaAllocator.Error![]align(DmaAllocator.page_size) u8 {
        const self: *const Self = @ptrCast(@alignCast(ctx));
        return self.page_allocator.allocPagesP(num_pages);
    }

    fn freePages(ctx: *anyopaque, slice: []u8) void {
        const self: *const Self = @ptrCast(@alignCast(ctx));
        self.page_allocator.freePagesP(slice);
    }

    fn virt2phys(ctx: *const anyopaque, vaddr: usize) usize {
        const self: *const Self = @ptrCast(@alignCast(ctx));
        return self.page_allocator.translateP(vaddr);
    }

    fn phys2virt(ctx: *const anyopaque, paddr: usize) usize {
        const self: *const Self = @ptrCast(@alignCast(ctx));
        return self.page_allocator.translateV(paddr);
    }
};

// =============================================================
// I/O Registers
// =============================================================

// =============================================================
// Root Complex Configuration Space Registers

const RcTlVdmCtrl0 = packed struct(u32) {
    _0: u16,
    enabled: bool,
    ignore_tag: bool,
    ignore_vendor_id: bool,
    _1: u13,
};

const RcTlVdmCtrl1 = packed struct(u32) {
    vndrid0: u16,
    vndrid1: u16,
};

const RcConfigVendorSpecific1 = packed struct(u32) {
    _0: u2,
    endian: enum(u2) { little = 0 },
    _1: u28,
};

const RcConfigPriv1Id3 = packed struct(u32) {
    interface: u8,
    subclass: u8,
    class: u8,
    _0: u8,
};

// =============================================================
// MDIO Registers etc

const RcDlMdioAddr = MdioAddr;

const RcDlMdioWrite = packed struct(u32) {
    value: u32,
};

const RcPlPhyCtrl15 = packed struct(u32) {
    pm_clk_period: u8,
    _0: u14,
    pll_pd_disable: bool,
    _1: u9,
};

// =============================================================
// Misc Registers

const MiscMiscCtrl = packed struct(u32) {
    scb2_size: u5,
    _0: u2,
    pcie_rcb_64b_mode: bool,
    _1: u2,
    pcie_rcb_mps_mode: bool,
    _2: u1,
    scb_access_en: bool,
    cfg_read_ur_mode: bool,
    _3: u6,
    max_burst_size: enum(u2) {
        b128 = 1,
        b256 = 2,
        b512 = 3,
    },
    scb1_size: u5,
    scb0_size: u5,
};

const MemWin0Low = packed struct(u32) {
    mem_win0_low: u32,
};

const MemWin0High = packed struct(u32) {
    mem_win0_high: u32,
};

const RcBar1ConfigLo = packed struct(u32) {
    size: u5,
    _rsvd: u7 = 0,
    pci_offset_lo: u20,
};

const RcBar1ConfigHi = packed struct(u32) {
    pci_offset_hi: u32,
};

const RcBar4ConfigLo = packed struct(u32) {
    size: u5,
    _rsvd: u7 = 0,
    pci_offset_lo: u20,
};

const RcBar4ConfigHi = packed struct(u32) {
    pci_offset_hi: u32,
};

const UbusBar1ConfigRemap = packed struct(u32) {
    access_en: bool,
    _rsvd: u11 = 0,
    cpu_addr_lo: u20,
};

const UbusBar1ConfigRemapHi = packed struct(u32) {
    cpu_addr_hi: u32,
};

const UbusBar4ConfigRemap = packed struct(u32) {
    access_en: bool,
    _rsvd: u11 = 0,
    cpu_addr_lo: u20,
};

const UbusBar4ConfigRemapHi = packed struct(u32) {
    cpu_addr_hi: u32,
};

const RcConfigRetryTimeout = packed struct(u32) {
    value: u32,
};

const Control = packed struct(u32) {
    l23_request: u1,
    _0: u1,
    perstb: u1,
    _1: u29,
};

const MemWin0BaseLimit = packed struct(u32) {
    _0: u4,
    mem_win0_base: u12,
    _1: u4,
    mem_win0_limit: u12,
};

const MemWin0BaseHi = packed struct(u32) {
    mem_win0_base_hi: u8,
    _0: u24,
};

const MemWin0LimitHi = packed struct(u32) {
    mem_win0_limit_hi: u8,
    _0: u24,
};

const MiscStatus = packed struct(u32) {
    _0: u4,
    link_up: bool,
    dl_active: bool,
    link_in_l23: bool,
    port: bool,
    _1: u24,
};

const PcieCtrl = packed struct(u32) {
    _0: u3,
    outbound_no_snoop: bool,
    outbound_ro: bool,
    en_vdm_qos_control: bool,
    _1: u26,
};

const MiscUbusCtrl = packed struct(u32) {
    _0: u13,
    reply_error_disable: bool,
    _1: u5,
    replay_dec_error_disable: bool,
    _2: u12,
};

const MiscUbusTimeout = packed struct(u32) {
    value: u32,
};

const MiscAxiIntfCtrl = packed struct(u32) {
    _0: u6,
    reqfifo_en_qos_propagation: bool,
    bridge_low_latency_mode: bool,
    _1: u3,
    dis_qos_gating_in_master: bool,
    en_qos_update_timing_fix: bool,
    en_rclk_qos_array_fix: bool,
    _2: u18,
};

const MiscVdmPriorityToQosMapHi = packed struct(u32) {
    value: u32,
};

const MiscVdmPriorityToQosMapLo = packed struct(u32) {
    value: u32,
};

const PcieMiscAxiReadErrorData = packed struct(u32) {
    value: u32,
};

const HardDebug = packed struct(u32) {
    _0: u1,
    clkreq_debug_enable: u1,
    _1: u1,
    perst_assert: u1,
    _2: u12,
    refclk_ovrd_enable: u1,
    _3: u3,
    refclk_ovrd_out: u1,
    l1ss_enable: u1,
    _5: u5,
    serdes_iddq: u1,
    _6: u4,
};

// =============================================================
// AER: Advanced Error Reporting

/// Extended capability ID for AER.
const extcap_id_aer = 1;

/// AER register set starting from the extended capability header.
const Aer = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, dd.pci.ExtCapHeader },
    .{ 0x04, AerUncorrectableErr },
    .{ 0x08, AerUncorrectableMask },
    .{ 0x0C, AerUncorrectableSeverity },
    .{ 0x10, AerCorrectableErr },
    .{ 0x14, AerCorrectableMask },
    .{ 0x18, AerCorrectableSeverity },
    .{ 0x1C, mmio.Marker(.log0) },
    .{ 0x20, mmio.Marker(.log1) },
    .{ 0x24, mmio.Marker(.log2) },
    .{ 0x28, mmio.Marker(.log3) },
});

/// Uncorrectable errors.
const AerUncorrectableErr = packed struct(u32) {
    /// Undefined.
    und: bool,
    /// Reserved.
    _0: u3 = 0,
    /// Data Link Protocol.
    data_link: bool,
    /// Surprise Down.
    surprise_down: bool,
    /// Reserved.
    _1: u6 = 0,
    /// Poisoned TLP.
    poisoned_tlp: bool,
    /// Flow Control Protocol.
    flow_control: bool,
    /// Completion timeout.
    comp_timeout: bool,
    /// Completer Abort.
    completer_abort: bool,

    /// Unexpected Completion.
    unexpected_completion: bool,
    /// Receiver Overflow.
    receiver_overflow: bool,
    /// Malformed TLP.
    malformed_tlp: bool,
    /// ECRC Error.
    ecrc_error: bool,
    /// Unsupported Request.
    unsupported_request: bool,
    /// ACS Violation.
    acs_violation: bool,
    /// Uncorrectable Internal Error.
    internal_error: bool,
    /// MC Blocked TLP.
    mc_blocked_tlp: bool,
    /// Atomic egress blocked.
    atomic_egress: bool,
    /// TLP prefix blocked.
    tlp_prefix: bool,
    /// Reserved.
    _2: u6 = 0,
};

/// Uncorrectable Error Mask.
const AerUncorrectableMask = packed struct(u32) { value: u32 };

/// Uncorrectable Error Severity.
const AerUncorrectableSeverity = packed struct(u32) { value: u32 };

/// Correctable Error Status.
const AerCorrectableErr = packed struct(u32) {
    /// Receiver Error.
    receiver_error: bool,
    /// Reserved.
    _0: u5 = 0,
    /// Bad TLP.
    bad_tlp: bool,
    /// Bad DLLP.
    bad_dllp: bool,

    /// REPLAY_NUM Rollover.
    rollover: bool,
    /// Reserved.
    _1: u3 = 0,
    /// Replay Timer Timeout.
    replay_timer_timeout: bool,
    /// Advisory Non-Fatal Error.
    advisory_non_fatal: bool,
    /// Corrected Internal Error.
    corrected_internal_error: bool,
    /// Reserved.
    _2: u17 = 0,
};

/// Correctable Error Mask.
const AerCorrectableMask = packed struct(u32) { value: u32 };

/// Correctable Error Severity.
const AerCorrectableSeverity = packed struct(u32) { value: u32 };

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.brcstb);
const arch = @import("arch").impl;
const common = @import("common");
const bits = common.bits;
const mmio = common.mmio;
const rtt = common.rtt;
const units = common.units;
const Console = common.Console;
const DmaAllocator = common.DmaAllocator;
const IoAllocator = common.IoAllocator;
const PageAllocator = common.PageAllocator;
const dd = @import("dd");
