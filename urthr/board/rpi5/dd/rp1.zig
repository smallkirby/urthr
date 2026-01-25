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

/// Physical address mapped to RP1 peripherals (BAR1).
const axi_peri_base: usize = pcie1_range.start;
/// Size in bytes of peripheral region's translation window.
const axi_peri_window_size: usize = 0x0040_0000;
/// Physical address mapped to RP1 Shared SRAM (BAR2).
const axi_sram_base: usize = axi_peri_base + axi_peri_window_size;
/// Size in bytes of Shared SRAM's translation window.
const axi_sram_window_size: usize = 0x0040_0000;

comptime {
    common.comptimeAssert(axi_peri_base % units.mib == 0, null);
    common.comptimeAssert((axi_peri_base / units.mib) >> 20 == 0, null);
}

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
            1 => {
                // Peripherals
                rtt.expectEqual(.mem32, bar.type);
                bar.setAddress(0, confio);
            },
            2 => {
                // Shared SRAM
                rtt.expectEqual(.mem32, bar.type);
                bar.setAddress(axi_peri_window_size, confio);
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

    // Setup translation windows.
    pcie.setOutTranslation(
        axi_peri_base,
        0,
        axi_peri_window_size + axi_sram_window_size,
        0,
    );
    // Setup inbound translation.
    pcie.setInTranslation(
        dma_range.pci,
        0,
        dma_range.size,
        2,
    );

    // Set configuration header.
    confio.modify(dd.pci.HeaderCommandStatus, .{
        .memory_space_enable = true,
        .bus_master_enable = true,
        .interrupt_disable = true,
    });

    // Map peripheral and shared SRAM region.
    const res_peri = try allocator.reserve(
        "RP1 PCIe Peripherals",
        axi_peri_base,
        axi_peri_window_size,
        null,
    );
    const res_sram = try allocator.reserve(
        "RP1 PCIe Shared SRAM",
        axi_sram_base,
        axi_sram_window_size,
        null,
    );
    const vperi = try allocator.ioremap(
        res_peri.phys,
        res_peri.size,
    );
    const vsram = try allocator.ioremap(
        res_sram.phys,
        res_sram.size,
    );

    // Set RP1 module base.
    rp1.setBase(vperi);

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

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.rp1);
const common = @import("common");
const mmio = common.mmio;
const rtt = common.rtt;
const units = common.units;
const IoAllocator = common.IoAllocator;
const dd = @import("dd");

const pcie = @import("pcie.zig");
const rp1fw = @import("rp1fw.zig");
const rp1mb = @import("rp1mb.zig");
