//! RP1 I/O Controller / Southbridge.

// =============================================================
// Module Definition
// =============================================================

var rp1 = mmio.Module(.{ .size = void }, &.{
    .{ 0x0000_0000, mmio.Marker(.sysinfo) },
    .{ 0x0000_8000, mmio.Marker(.syscfg) },
    .{ 0x0000_C000, mmio.Marker(.otp) },
    .{ 0x0001_0000, mmio.Marker(.resets) },
    .{ 0x0001_8000, mmio.Marker(.clocks_main) },
    .{ 0x0001_C000, mmio.Marker(.clocks_video) },
    .{ 0x0002_0000, mmio.Marker(.pll_sys) },
    .{ 0x0002_4000, mmio.Marker(.pll_audio) },
    .{ 0x0002_8000, mmio.Marker(.pll_video) },
    .{ 0x0003_0000, mmio.Marker(.uart0) },
    .{ 0x0003_4000, mmio.Marker(.uart1) },
    .{ 0x0003_8000, mmio.Marker(.uart2) },
    .{ 0x0003_C000, mmio.Marker(.uart3) },
    .{ 0x0004_0000, mmio.Marker(.uart4) },
    .{ 0x0004_4000, mmio.Marker(.uart5) },
    .{ 0x000B_0000, mmio.Marker(.sdio0_cfg) },
    .{ 0x000B_4000, mmio.Marker(.sdio1_cfg) },
    .{ 0x000D_0000, mmio.Marker(.io_bank0) },
    .{ 0x000E_0000, mmio.Marker(.rio_bank0) },
    .{ 0x000F_0000, mmio.Marker(.pad_bank0) },
    .{ 0x0010_0000, mmio.Marker(.eth) },
    .{ 0x0010_4000, mmio.Marker(.eth_cfg) },
    .{ 0x0010_8000, mmio.Marker(.pcie) },
    .{ 0x0018_0000, mmio.Marker(.sdio0) },
    .{ 0x0018_4000, mmio.Marker(.sdio1) },
    .{ 0x0040_0000, mmio.Marker(.end) },
}){};

const pcie0_range = common.Range{
    .start = 0x001C_0000_0000,
    .end = 0x001F_0000_0000,
};
const pcie1_range = common.Range{
    .start = 0x001F_0000_0000,
    .end = 0x0020_0000_0000,
};

const DmaRange = struct {
    /// Inbound PCIe address.
    pci: u64,
    /// AXI address.
    axi: usize,
    /// Size in bytes.
    size: usize,
};
// RP1 translates 0x10_0000_0000 to PCIe 0x10_0000_0000.
const dma_range = DmaRange{
    .pci = 0x10_0000_0000,
    .axi = 0x10_0000_0000,
    .size = 0x10_0000_0000,
};
const dma_offset = dma_range.axi;

/// RP1 peripherals (BAR1).
const peri_range = DmaRange{
    .pci = 0,
    .axi = pcie1_range.start,
    .size = 0x0040_0000,
};
/// RP1 Shared SRAM (BAR2).
const sram_range = DmaRange{
    .pci = peri_range.pci + peri_range.size,
    .axi = peri_range.axi + peri_range.size,
    .size = 0x0040_0000,
};
/// RP1 MSI-X table (BAR0).
const msix_range = DmaRange{
    .pci = sram_range.pci + sram_range.size,
    .axi = sram_range.axi + sram_range.size,
    .size = 0x0001_0000,
};
/// MIPS0 interrupt controller.
const mips0_range = DmaRange{
    .pci = 0xFF_FFFF_F000,
    .axi = 0x10_0013_0000,
    .size = 0x0000_1000,
};

/// RP1 IRQ number.
const MsiIrq = enum(u8) {
    /// Ethernet.
    eth = 6,
};

/// Virtual address base of RP1 peripherals.
var vperi: usize = undefined;
/// Virtual address base of RP1 Shared SRAM.
var vsram: usize = undefined;
/// Virtual address of MSI-X table.
var vmsix: usize = undefined;

// =============================================================
// API
// =============================================================

/// Initialize RP1 controller.
pub fn init(allocator: IoAllocator) IoAllocator.Error!void {
    var confio = pcie.getConfIoType0();
    confio.setAddress(1, 0, 0);

    // Read configuration header.
    const header_vendor_dev = confio.read(dd.pci.HeaderVendorDevice);
    log.info(
        "RP1 Vendor ID: 0x{X:0>4}, Device ID: 0x{X:0>4}",
        .{ header_vendor_dev.vendor_id, header_vendor_dev.device_id },
    );
    rtt.expectEqual(0x1DE4, header_vendor_dev.vendor_id);
    rtt.expectEqual(0x0001, header_vendor_dev.device_id);

    const class = confio.read(dd.pci.HeaderRevClass);
    log.info(
        "RP1 Class Code: {X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}",
        .{ class.base_class, class.sub_class, class.prog_if, class.revision_id },
    );

    // Configure BARs.
    var bars_buffer: [6]dd.pci.BarInfo = undefined;
    var bars = dd.pci.parseBars(confio, &bars_buffer);
    for (bars) |bar| {
        switch (bar.index) {
            0 => {
                // MSI-X table and PBA
                rtt.expectEqual(.mem32, bar.type);
                bar.setAddress(msix_range.pci, confio);
            },
            1 => {
                // Peripherals
                rtt.expectEqual(.mem32, bar.type);
                bar.setAddress(peri_range.pci, confio);
            },
            2 => {
                // Shared SRAM
                rtt.expectEqual(.mem32, bar.type);
                bar.setAddress(sram_range.pci, confio);
            },
            else => {},
        }
    }

    // Print configured BARs.
    bars = dd.pci.parseBars(confio, &bars_buffer);
    for (bars) |bar| {
        log.info(
            "BAR{}: 0x{X:0>8} - 0x{X:0>8} ({t})",
            .{ bar.index, bar.address, bar.address + bar.size(), bar.type },
        );
    }

    // Setup translation windows (BAR1 + BAR2 + BAR0).
    pcie.setOutTranslation(
        peri_range.axi,
        0,
        common.util.roundup(peri_range.size + sram_range.size + msix_range.size, units.mib),
        0,
    );

    // Setup inbound translation.
    pcie.setInTranslation(
        dma_range.pci,
        0,
        dma_range.size,
        2,
    );
    pcie.setInTranslation(
        mips0_range.pci,
        mips0_range.axi,
        mips0_range.size,
        1,
    );

    // Set configuration header.
    confio.modify(dd.pci.HeaderCommandStatus, .{
        .memory_space_enable = true,
        .bus_master_enable = true,
        .interrupt_disable = false,
    });

    // Map peripheral, SRAM, and MSI-X table region.
    const res_peri = try allocator.reserve(
        "RP1 PCIe Peripherals",
        peri_range.axi,
        peri_range.size,
        null,
    );
    const res_sram = try allocator.reserve(
        "RP1 PCIe Shared SRAM",
        sram_range.axi,
        sram_range.size,
        null,
    );
    const res_msix = try allocator.reserve(
        "RP1 PCIe MSI-X Table",
        msix_range.axi,
        msix_range.size,
        null,
    );
    vperi = try allocator.ioremap(
        res_peri.phys,
        res_peri.size,
    );
    vsram = try allocator.ioremap(
        res_sram.phys,
        res_sram.size,
    );
    vmsix = try allocator.ioremap(
        res_msix.phys,
        res_msix.size,
    );

    // Set RP1 module base.
    rp1.setBase(vperi);

    // Setup MSI-X.
    try setupMsix(allocator);

    // Map modules.
    try mapPeris(allocator, res_peri);

    // Init RP1 Shared SRAM.
    rp1fw.setBase(vsram);

    // Init mailbox.
    const vmb = try allocator.ioremap(
        res_peri.phys + rp1.getMarkerOffset(.syscfg),
        0x0000_4000,
    );
    rp1mb.init(vmb);

    // Get FW version.
    const rp1version = rp1fw.getVersion();
    log.info("RP1 Firmware Version: {X:0>40}", .{rp1version});

    // Get Chip ID.
    const chipid: *const volatile u32 = @ptrFromInt(rp1.getMarkerAddress(.sysinfo));
    log.info("RP1 Chip ID: 0x{X:0>8}", .{chipid.*});
    rtt.expectEqual(0x2000_1927, chipid.*);
}

/// Get the base address of I/O Bank registers.
pub fn getIoBankBase() usize {
    return rp1.getMarkerAddress(.io_bank0);
}

/// Get the base address of RIO Bank registers.
pub fn getRioBase() usize {
    return rp1.getMarkerAddress(.rio_bank0);
}

/// Get the base address of Pad Bank registers.
pub fn getPadsBase() usize {
    return rp1.getMarkerAddress(.pad_bank0);
}

/// Get the base address of Main Clocks registers.
pub fn getClocksMain() usize {
    return rp1.getMarkerAddress(.clocks_main);
}

/// Get the base address of Ethernet registers.
pub fn getEthrBase() usize {
    return rp1.getMarkerAddress(.eth);
}

/// Get the base address of Ethernet configuration registers.
pub fn getEthrCfgBase() usize {
    return rp1.getMarkerAddress(.eth_cfg);
}

/// Map peripherals of RP1.
fn mapPeris(allocator: IoAllocator, root: *IoAllocator.Resource) IoAllocator.Error!void {
    _ = try allocator.reserve(
        "sysinfo",
        root.phys + rp1.getMarkerOffset(.sysinfo),
        0x0000_4000,
        root,
    );
    _ = try allocator.reserve(
        "syscfg",
        root.phys + rp1.getMarkerOffset(.syscfg),
        0x0000_4000,
        root,
    );
    _ = try allocator.reserve(
        "clocks_main",
        root.phys + rp1.getMarkerOffset(.clocks_main),
        0x0000_4000,
        root,
    );
    _ = try allocator.reserve(
        "uart0",
        root.phys + rp1.getMarkerOffset(.uart0),
        0x0000_4000,
        root,
    );
    _ = try allocator.reserve(
        "sdio0_cfg",
        root.phys + rp1.getMarkerOffset(.sdio0_cfg),
        0x0000_4000,
        root,
    );
    _ = try allocator.reserve(
        "sdio1_cfg",
        root.phys + rp1.getMarkerOffset(.sdio1_cfg),
        0x0000_4000,
        root,
    );
    _ = try allocator.reserve(
        "io_bank",
        root.phys + rp1.getMarkerOffset(.io_bank0),
        0x0000_C000,
        root,
    );
    _ = try allocator.reserve(
        "rio_bank",
        root.phys + rp1.getMarkerOffset(.rio_bank0),
        0x0000_C000,
        root,
    );
    _ = try allocator.reserve(
        "pad_bank",
        root.phys + rp1.getMarkerOffset(.pad_bank0),
        0x0000_C000,
        root,
    );
    _ = try allocator.reserve(
        "eth",
        root.phys + rp1.getMarkerOffset(.eth),
        0x0000_4000,
        root,
    );
    _ = try allocator.reserve(
        "eth_cfg",
        root.phys + rp1.getMarkerOffset(.eth_cfg),
        0x0000_4000,
        root,
    );
    _ = try allocator.reserve(
        "sdio0",
        root.phys + rp1.getMarkerOffset(.sdio0),
        0x0000_4000,
        root,
    );
    _ = try allocator.reserve(
        "sdio1",
        root.phys + rp1.getMarkerOffset(.sdio1),
        0x0000_4000,
        root,
    );
}

/// MIP module definition.
const Mip = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x020, mmio.Marker(.int_cfgl_host) },
    .{ 0x030, mmio.Marker(.int_cfgh_host) },
    .{ 0x040, mmio.Marker(.int_maskl_host) },
    .{ 0x050, mmio.Marker(.int_maskh_host) },
    .{ 0x060, mmio.Marker(.int_maskl_vcpu) },
    .{ 0x070, mmio.Marker(.int_maskh_vcpu) },
});

/// PCIe endpoint configuration module definition.
const PcieCfg = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x008, mmio.Marker(.msix_cfgs) },
});

/// MSI-X Configuration Register.
const MsixCfg = packed struct(u32) {
    /// Interrupt enable.
    enable: bool,
    /// ORed with interrupt source for test purposes.
    testor: bool,
    /// Interrupt acknowledge.
    ///
    /// Writing a 1 clears the interrupt mask that was automatically set when the interrupt was generated.
    iack: bool,
    /// Enable IACK functionality.
    iack_en: bool,
    /// Reserved.
    _rsvd0: u8 = 0,
    /// PCIe traffic class.
    tc: u3,
    /// Reserved.
    _rsvd1: u1 = 0,
    /// PCIe function.
    func: u3,
    /// Reserved.
    _rsvd2: u13 = 0,
};

/// Setup MSI-X.
fn setupMsix(allocator: IoAllocator) IoAllocator.Error!void {
    var confio = pcie.getConfIoType0();
    confio.setAddress(1, 0, 0);

    // Check for MSI-X capability.
    const msix = dd.pci.parseMsixConfig(confio) orelse
        @panic("RP1 does not support MSI-X");

    log.debug("MSI-X table: size={d}, BAR={d}", .{
        msix.table_size,
        msix.table_bar,
    });

    // Unmask interrupts.
    {
        const mip0_base = try allocator.ioremap(
            mips0_range.axi,
            mips0_range.size,
        );
        // TODO: deallocate the I/O region.
        // defer allocator.iounmap(mip0_base, mips0_range.size);

        var mip0 = Mip.new(mip0_base);
        // Unmask all for the host.
        @as(*volatile u32, @ptrFromInt(mip0.getMarkerAddress(.int_maskl_host))).* = 0;
        @as(*volatile u32, @ptrFromInt(mip0.getMarkerAddress(.int_maskh_host))).* = 0;
        // Mask all for the VPU and edge-triggered.
        @as(*volatile u32, @ptrFromInt(mip0.getMarkerAddress(.int_maskl_vcpu))).* = 0xFFFF_FFFF;
        @as(*volatile u32, @ptrFromInt(mip0.getMarkerAddress(.int_maskh_vcpu))).* = 0xFFFF_FFFF;
        @as(*volatile u32, @ptrFromInt(mip0.getMarkerAddress(.int_cfgl_host))).* = 0xFFFF_FFFF;
        @as(*volatile u32, @ptrFromInt(mip0.getMarkerAddress(.int_cfgh_host))).* = 0xFFFF_FFFF;
    }

    // Setup MSI-X table entries.
    {
        const table = dd.pci.MsixTable{
            .base = vmsix + msix.table_offset,
        };

        // Ethernet
        const irq_eth: u32 = @intFromEnum(MsiIrq.eth);
        table.setEntry(irq_eth, mips0_range.pci, irq_eth);
        table.maskEntry(irq_eth, false);
    }

    // Setup PCIe MSI-X configuration.
    {
        const cfg = PcieCfg.new(rp1.getMarkerAddress(.pcie));

        // Ethernet
        msixConfigSet(cfg, .eth, std.mem.zeroInit(MsixCfg, .{
            .enable = true,
            .iack_en = true,
        }));
    }

    // Enable global.
    dd.pci.enableMsix(confio, msix.cap_offset);
}

/// Set MSI-X configuration register.
fn msixConfigSet(cfg: PcieCfg, irq: MsiIrq, value: MsixCfg) void {
    const set_offset = 0x800;
    const ptr: [*]volatile u32 = @ptrFromInt(cfg.getMarkerAddress(.msix_cfgs) + set_offset);

    ptr[@intFromEnum(irq)] = @bitCast(value);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.rp1);
const common = @import("common");
const mmio = common.mmio;
const rtt = common.rtt;
const units = common.units;
const IoAllocator = common.mem.IoAllocator;
const dd = @import("dd");

const pcie = @import("pcie.zig");
const rp1fw = @import("rp1fw.zig");
const rp1mb = @import("rp1mb.zig");
