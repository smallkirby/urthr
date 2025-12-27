//! Physical memory map of Raspberry Pi 4B.
//!
//! This file is referenced by mkconst tool.

/// Available DRAM regions.
pub const drams = [_]Range{
    // 1016 MiB
    .{
        .start = 0x0000_0000,
        .end = 0x3F80_0000,
    },
    // 7168 MiB
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
    .start = drams[0].start,
    .end = loader,
};

/// Physical load address of the kernel image.
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

/// PL011 UART (debug port)
pub const pl011 = Range{
    .start = 0x0010_7D00_1000,
    .end = 0x0010_7D00_2000,
};

// =============================================================
// Imports
// =============================================================

const Range = @import("common").Range;
