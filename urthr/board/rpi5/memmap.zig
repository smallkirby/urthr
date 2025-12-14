//! Physical memory map of Raspberry Pi 4B.
//!
//! This file is referenced by mkconst tool.

/// DRAM0 (1016 MiB).
pub const primary_dram = Range{
    .start = 0x0000_0000,
    .end = 0x3F80_0000,
};

/// Available DRAM regions.
pub const drams = [_]Range{
    primary_dram,
    .{
        .start = 0x0000_4000_0000,
        .end = 0x0002_0000_0000,
    },
};

// =============================================================
// Kernel
// =============================================================

/// Physical load address of the bootloader.
pub const loader = 0x0020_0000;

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
/// Physical load address of the kernel.
pub const kernel_entry = 0x0040_0000;

// =============================================================
// Peripherals
// =============================================================

/// PL011 UART (debug port)
pub const pl011 = Range{
    .start = 0x0010_7D00_1000,
    .end = 0x0010_7D00_2000,
};

// =============================================================
// Imports
// =============================================================

const Range = @import("common").Range;
