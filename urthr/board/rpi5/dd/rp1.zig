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

/// Physical address mapped to RP1 peripherals (BAR1).
const axi_peri_base: usize = pcie1_range.start;
/// Size in bytes of peripheral region's translation window.
const axi_peri_window_size: usize = 0x0040_0000;

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
    pcie.setOutTranslation(axi_peri_base, 0, axi_peri_window_size, 0);

    // Set configuration header.
    confio.modify(dd.pci.HeaderCommandStatus, .{
        .memory_space_enable = true,
        .bus_master_enable = true,
    });

    // Map peripheral region.
    const resource = try allocator.reserve(
        "RP1 PCIe Peripherals",
        axi_peri_base,
        axi_peri_window_size,
        null,
    );
    const vperi = try allocator.ioremap(
        resource.phys,
        resource.size,
    );

    // Set RP1 module base.
    rp1.setBase(vperi);

    // Map modules.
    _ = try allocator.reserve(
        "sysinfo",
        resource.phys + rp1.getMarkerOffset(.sysinfo),
        0x0000_4000,
        resource,
    );
    _ = try allocator.reserve(
        "syscfg",
        resource.phys + rp1.getMarkerOffset(.syscfg),
        0x0000_4000,
        resource,
    );
    _ = try allocator.reserve(
        "uart0",
        resource.phys + rp1.getMarkerOffset(.uart0),
        0x0000_4000,
        resource,
    );
    _ = try allocator.reserve(
        "sdio0_cfg",
        resource.phys + rp1.getMarkerOffset(.sdio0_cfg),
        0x0000_4000,
        resource,
    );
    _ = try allocator.reserve(
        "sdio1_cfg",
        resource.phys + rp1.getMarkerOffset(.sdio1_cfg),
        0x0000_4000,
        resource,
    );
    _ = try allocator.reserve(
        "sdio0",
        resource.phys + rp1.getMarkerOffset(.sdio0),
        0x0000_4000,
        resource,
    );
    _ = try allocator.reserve(
        "sdio1",
        resource.phys + rp1.getMarkerOffset(.sdio1),
        0x0000_4000,
        resource,
    );

    // Get Chip ID.
    const chipid: *const volatile u32 = @ptrFromInt(rp1.getMarkerAddress(.sysinfo));
    log.info("Chip ID: 0x{X:0>8}", .{chipid.*});
    rtt.expectEqual(0x2000_1927, chipid.*);
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
