//! RP1 I/O Controller / Southbridge.

// =============================================================
// Module Definition
// =============================================================

var rp1 = mmio.Module(.{ .size = void }, .{
    Mrk(0x0000_0000, .sysinfo),
    Mrk(0x0000_8000, .syscfg),
    Mrk(0x0000_C000, .otp),
    Mrk(0x0001_0000, .resets),
    Mrk(0x0001_8000, .clocks_main),
    Mrk(0x0001_C000, .clocks_video),
    Mrk(0x0002_0000, .pll_sys),
    Mrk(0x0002_4000, .pll_audio),
    Mrk(0x0002_8000, .pll_video),
    Mrk(0x0003_0000, .uart0),
    Mrk(0x0003_4000, .uart1),
    Mrk(0x0003_8000, .uart2),
    Mrk(0x0003_C000, .uart3),
    Mrk(0x0004_0000, .uart4),
    Mrk(0x0004_4000, .uart5),
    Mrk(0x000B_0000, .sdio0_cfg),
    Mrk(0x000B_4000, .sdio1_cfg),
    Mrk(0x000D_0000, .io_bank0),
    Mrk(0x000E_0000, .rio_bank0),
    Mrk(0x000F_0000, .pad_bank0),
    Mrk(0x0010_0000, .eth),
    Mrk(0x0010_4000, .eth_cfg),
    Mrk(0x0010_8000, .pcie),
    Mrk(0x0020_0000, .usbhost0),
    Mrk(0x0030_0000, .usbhost1),
    Mrk(0x0018_0000, .sdio0),
    Mrk(0x0018_4000, .sdio1),
    Mrk(0x0040_0000, .end),
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
/// MIP0 interrupt controller.
const mip0_range = DmaRange{
    .pci = 0xFF_FFFF_F000,
    .axi = 0x10_0013_0000,
    .size = 0x0000_1000,
};

/// RP1 IRQ number.
///
/// ref. https://github.com/raspberrypi/linux/blob/0ad641150c52aaaaba11365dab3efa29a68eb0ba/include/dt-bindings/mfd/rp1.h#L106
const MsiIrq = enum(u8) {
    /// Ethernet.
    eth = 6,
    /// USB Host0 (USB 2.0).
    usb0 = 30,
    /// USB Host1 (USB 3.0).
    usb1 = 36,
};

/// SPI interrupts offset.
const spi_offset = 32;

/// Offset of MIP0's SPI interrupts.
const mip0_spi_offset = 128;

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
    const host = pcie.interface();
    const io = host.getTypedIo(.{ .bus = 1 }, dd.pci.HeaderType0);

    // Read configuration header.
    const header_vendor_dev = io.readReg(dd.pci.HeaderVendorDevice);
    log.info(
        "RP1 Vendor ID: 0x{X:0>4}, Device ID: 0x{X:0>4}",
        .{ header_vendor_dev.vendor_id, header_vendor_dev.device_id },
    );
    rtt.expectEqual(0x1DE4, header_vendor_dev.vendor_id);
    rtt.expectEqual(0x0001, header_vendor_dev.device_id);

    const class = io.readReg(dd.pci.HeaderRevClass);
    log.info(
        "RP1 Class Code: {X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}",
        .{ class.base_class, class.sub_class, class.prog_if, class.revision_id },
    );

    // Configure BARs.
    var bars_buffer: [6]dd.pci.BarInfo = undefined;
    var bars = io.parseBars(&bars_buffer);
    for (bars) |bar| {
        switch (bar.index) {
            0 => {
                // MSI-X table and PBA
                rtt.expectEqual(.mem32, bar.type);
                io.setBarAddress(bar, msix_range.pci);
            },
            1 => {
                // Peripherals
                rtt.expectEqual(.mem32, bar.type);
                io.setBarAddress(bar, peri_range.pci);
            },
            2 => {
                // Shared SRAM
                rtt.expectEqual(.mem32, bar.type);
                io.setBarAddress(bar, sram_range.pci);
            },
            else => {},
        }
    }

    // Print configured BARs.
    bars = io.parseBars(&bars_buffer);
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
        mip0_range.pci,
        mip0_range.axi,
        mip0_range.size,
        1,
    );

    // Set configuration header.
    io.modifyReg(dd.pci.HeaderCommandStatus, .{
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
        .device,
    );
    vsram = try allocator.ioremap(
        res_sram.phys,
        res_sram.size,
        .device,
    );
    vmsix = try allocator.ioremap(
        res_msix.phys,
        res_msix.size,
        .device,
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
    rp1mb.init(rp1.addressOf(.syscfg));

    // Get FW version.
    const rp1version = rp1fw.getVersion();
    log.info("RP1 Firmware Version: {X:0>40}", .{rp1version});

    // Get Chip ID.
    const chipid: *const volatile u32 = @ptrFromInt(rp1.addressOf(.sysinfo));
    log.info("RP1 Chip ID: 0x{X:0>8}", .{chipid.*});
    rtt.expectEqual(0x2000_1927, chipid.*);
}

/// Get the base address of I/O Bank registers.
pub fn getIoBankBase() usize {
    return rp1.addressOf(.io_bank0);
}

/// Get the base address of RIO Bank registers.
pub fn getRioBase() usize {
    return rp1.addressOf(.rio_bank0);
}

/// Get the base address of Pad Bank registers.
pub fn getPadsBase() usize {
    return rp1.addressOf(.pad_bank0);
}

/// Get the base address of Main Clocks registers.
pub fn getClocksMain() usize {
    return rp1.addressOf(.clocks_main);
}

/// Get the base address of Ethernet registers.
pub fn getEthrBase() usize {
    return rp1.addressOf(.eth);
}

/// Get the base address of Ethernet configuration registers.
pub fn getEthrCfgBase() usize {
    return rp1.addressOf(.eth_cfg);
}

/// Get the base address of usbhost0 registers.
pub fn getUsbHost0Base() usize {
    return rp1.addressOf(.usbhost0);
}

/// Get the base address of usbhost1 registers.
pub fn getUsbHost1Base() usize {
    return rp1.addressOf(.usbhost1);
}

/// Get the IRQ number of RP1 peripherals.
pub fn getIrqNumber(irq: MsiIrq) u16 {
    return @backingInt(irq) + mip0_spi_offset + spi_offset;
}

/// Get the MSI-X IRQ corresponding to the given IRQ number.
///
/// Returns null if the IRQ does not correspond to any MSI-X.
pub fn tryGetMsix(irq: usize) ?MsiIrq {
    if (irq < mip0_spi_offset + spi_offset) {
        return null;
    }

    const spi = irq - (mip0_spi_offset + spi_offset);
    return std.enums.fromInt(MsiIrq, spi);
}

/// Map peripherals of RP1.
fn mapPeris(allocator: IoAllocator, root: *IoAllocator.Resource) IoAllocator.Error!void {
    _ = try allocator.reserve(
        "sysinfo",
        root.phys + rp1.offsetOf(.sysinfo),
        0x0000_4000,
        root,
    );
    _ = try allocator.reserve(
        "syscfg",
        root.phys + rp1.offsetOf(.syscfg),
        0x0000_4000,
        root,
    );
    _ = try allocator.reserve(
        "clocks_main",
        root.phys + rp1.offsetOf(.clocks_main),
        0x0000_4000,
        root,
    );
    _ = try allocator.reserve(
        "uart0",
        root.phys + rp1.offsetOf(.uart0),
        0x0000_4000,
        root,
    );
    _ = try allocator.reserve(
        "sdio0_cfg",
        root.phys + rp1.offsetOf(.sdio0_cfg),
        0x0000_4000,
        root,
    );
    _ = try allocator.reserve(
        "sdio1_cfg",
        root.phys + rp1.offsetOf(.sdio1_cfg),
        0x0000_4000,
        root,
    );
    _ = try allocator.reserve(
        "io_bank",
        root.phys + rp1.offsetOf(.io_bank0),
        0x0000_C000,
        root,
    );
    _ = try allocator.reserve(
        "rio_bank",
        root.phys + rp1.offsetOf(.rio_bank0),
        0x0000_C000,
        root,
    );
    _ = try allocator.reserve(
        "pad_bank",
        root.phys + rp1.offsetOf(.pad_bank0),
        0x0000_C000,
        root,
    );
    _ = try allocator.reserve(
        "eth",
        root.phys + rp1.offsetOf(.eth),
        0x0000_4000,
        root,
    );
    _ = try allocator.reserve(
        "eth_cfg",
        root.phys + rp1.offsetOf(.eth_cfg),
        0x0000_4000,
        root,
    );
    _ = try allocator.reserve(
        "usbhost0",
        root.phys + rp1.offsetOf(.usbhost0),
        0x0000_4000,
        root,
    );
    _ = try allocator.reserve(
        "usbhost1",
        root.phys + rp1.offsetOf(.usbhost1),
        0x0000_4000,
        root,
    );
    _ = try allocator.reserve(
        "sdio0",
        root.phys + rp1.offsetOf(.sdio0),
        0x0000_4000,
        root,
    );
    _ = try allocator.reserve(
        "sdio1",
        root.phys + rp1.offsetOf(.sdio1),
        0x0000_4000,
        root,
    );
}

/// MIP module definition.
const Mip = mmio.Module(.{ .size = u32 }, .{
    Mrk(0x020, .int_cfgl_host),
    Mrk(0x030, .int_cfgh_host),
    Mrk(0x040, .int_maskl_host),
    Mrk(0x050, .int_maskh_host),
    Mrk(0x060, .int_maskl_vcpu),
    Mrk(0x070, .int_maskh_vcpu),
});

/// PCIe endpoint configuration module definition.
const PcieCfg = mmio.Module(.{ .size = u32 }, .{
    Mrk(0x008, .msix_cfgs),
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
    _4: u8 = 0,
    /// PCIe traffic class.
    tc: u3,
    /// Reserved.
    _15: u1 = 0,
    /// PCIe function.
    func: u3,
    /// Reserved.
    _19: u13 = 0,
};

/// Setup MSI-X.
fn setupMsix(allocator: IoAllocator) IoAllocator.Error!void {
    const host = pcie.interface();
    const addr = dd.pci.DevAddr{ .bus = 1 };

    // Check for MSI-X capability.
    const msix = dd.pci.parseMsixConfig(host, addr) orelse
        @panic("RP1 does not support MSI-X");

    log.debug("MSI-X table: size={d}, BAR={d}", .{
        msix.table_size,
        msix.table_bar,
    });

    // Unmask interrupts.
    {
        const mip0_base = try allocator.ioremap(
            mip0_range.axi,
            mip0_range.size,
            .device,
        );
        // TODO: deallocate the I/O region.
        // defer allocator.iounmap(mip0_base, mip0_range.size);

        var mip0 = Mip.new(mip0_base);
        // Unmask all for the host.
        @as(*volatile u32, @ptrFromInt(mip0.addressOf(.int_maskl_host))).* = 0;
        @as(*volatile u32, @ptrFromInt(mip0.addressOf(.int_maskh_host))).* = 0;
        // Mask all for the VPU and edge-triggered.
        @as(*volatile u32, @ptrFromInt(mip0.addressOf(.int_maskl_vcpu))).* = 0xFFFF_FFFF;
        @as(*volatile u32, @ptrFromInt(mip0.addressOf(.int_maskh_vcpu))).* = 0xFFFF_FFFF;
        @as(*volatile u32, @ptrFromInt(mip0.addressOf(.int_cfgl_host))).* = 0xFFFF_FFFF;
        @as(*volatile u32, @ptrFromInt(mip0.addressOf(.int_cfgh_host))).* = 0xFFFF_FFFF;
    }

    // Setup MSI-X table entries.
    {
        const table = dd.pci.MsixTable{
            .base = vmsix + msix.table_offset,
        };

        // Ethernet
        const irq_eth: u32 = @backingInt(MsiIrq.eth);
        table.setEntry(irq_eth, mip0_range.pci, irq_eth);
        table.maskEntry(irq_eth, false);

        // USB Host1
        const irq_usb1: u32 = @backingInt(MsiIrq.usb1);
        table.setEntry(irq_usb1, mip0_range.pci, irq_usb1);
        table.maskEntry(irq_usb1, false);
    }

    // Setup PCIe MSI-X configuration.
    {
        const cfg = PcieCfg.new(rp1.addressOf(.pcie));

        // Ethernet
        msixConfigSet(cfg, .eth, std.mem.zeroInit(MsixCfg, .{
            .enable = true,
            .iack_en = true,
        }));

        // USB Host1
        msixConfigSet(cfg, .usb1, std.mem.zeroInit(MsixCfg, .{
            .enable = true,
            .iack_en = true,
        }));
    }

    // Enable global.
    dd.pci.enableMsix(host, addr, msix.cap_offset);
}

/// Set MSI-X configuration register.
fn msixConfigSet(cfg: PcieCfg, irq: MsiIrq, value: MsixCfg) void {
    const set_offset = 0x800;
    const ptr: [*]volatile u32 = @ptrFromInt(cfg.addressOf(.msix_cfgs) + set_offset);

    ptr[@backingInt(irq)] = @bitCast(value);
}

/// Acknowledge MSI-X interrupt.
pub fn ackMsix(irq: MsiIrq) void {
    const cfg = PcieCfg.new(rp1.addressOf(.pcie));

    msixConfigSet(cfg, irq, std.mem.zeroInit(MsixCfg, .{
        .iack = true,
    }));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.rp1);
const common = @import("common");
const mmio = common.io.mmio;
const Mrk = common.io.Mrk;
const rtt = common.rtt;
const units = common.units;
const IoAllocator = common.mem.IoAllocator;
const dd = @import("dd");

const pcie = @import("pcie.zig");
const rp1fw = @import("rp1fw.zig");
const rp1mb = @import("rp1mb.zig");
