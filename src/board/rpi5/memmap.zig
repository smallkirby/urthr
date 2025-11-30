//! Physical memory map of Raspberry Pi 4B.
//!
//! This file is compiled into C-style header file and used in linker script and assembly code.

/// DRAM0 (1016 MiB).
pub const dram = Range{
    .start = 0x0000_0000,
    .end = 0x3F80_0000,
};

// =============================================================
// Kernel
// =============================================================

/// Physical load address of the bootloader.
pub const loader_phys = 0x0020_0000;
/// DRAM region reserved for the bootloader.
///
/// Bootloader uses this region for its own purposes such as allocating page tables.
///
/// Kernel can use the region after it ensures that the region is free.
pub const loader_reserved = Range{
    .start = dram.start,
    .end = dram.start + 0x0010_0000,
};

/// Physical load address of the kernel.
pub const kernel_phys = 0x0040_0000;

/// Virtual load address of the kernel.
pub const kernel_virt = 0xFFFF_FFFF_8040_0000;

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
