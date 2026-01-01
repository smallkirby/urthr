//! Physical memory map of Raspberry Pi 4B.
//!
//! This file is referenced by mkconst tool.

/// Available DRAM regions.
pub const drams = [_]Range{
    // 2 GiB
    .{
        .start = 0x0000_0000,
        .end = 0x8000_0000,
    },
};

// =============================================================
// Kernel
// =============================================================

/// Physical load address of the bootloader.
pub const loader = 0x0008_0000;

/// DRAM region reserved for the bootloader.
///
/// Bootloader uses this region for its own purposes such as allocating page tables.
///
/// Kernel can use the region after it ensures that the region is free.
pub const loader_reserved = Range{
    .start = drams[0].start,
    .end = loader,
};

/// Physical load address of the kernel
pub const kernel = 0x0040_0000;

comptime {
    if (loader_reserved.end > loader) {
        @compileError("Condition not met: loader_reserved.end <= loader");
    }
    if (loader >= kernel) {
        @compileError("Condition not met: loader < kernel");
    }
    if (kernel >= drams[0].end) {
        @compileError("Condition not met: kernel < drams[0].end");
    }
}

// =============================================================
// Peripherals
// =============================================================

/// Base address of peripheral registers.
pub const peri_base = 0xFE00_0000;

/// Power management block.
pub const pm = Range{
    .start = peri_base + 0x0010_0000,
    .end = peri_base + 0x0010_1000,
};

/// GPIO
pub const gpio = Range{
    .start = peri_base + 0x0020_0000,
    .end = peri_base + 0x0020_1000,
};

/// PL011 UART
pub const pl011 = Range{
    .start = peri_base + 0x0020_1000,
    .end = peri_base + 0x0020_2000,
};

/// SD Host Controller Interface.
pub const sdhost = Range{
    .start = peri_base + 0x0030_0000,
    .end = peri_base + 0x0030_1000,
};

// =============================================================
// Imports
// =============================================================

const Range = @import("common").Range;
