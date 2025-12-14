//! Physical memory map of Raspberry Pi 4B.
//!
//! This file is referenced by mkconst tool.

/// DRAM (2GiB).
pub const primary_dram = Range{
    .start = 0x0000_0000,
    .end = 0x8000_0000,
};

/// Available DRAM regions.
pub const drams = [_]Range{
    primary_dram,
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
    .start = primary_dram.start,
    .end = primary_dram.start + 0x0010_0000,
};

/// Physical address of the kernel.
pub const kernel = 0x0000_0000;
/// Physical load address of the kernel entry point.
pub const kernel_entry = 0x0040_0000;

// =============================================================
// Peripherals
// =============================================================

/// Base address of peripheral registers.
pub const peri_base = 0xFE00_0000;

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

// =============================================================
// Imports
// =============================================================

const Range = @import("common").Range;
