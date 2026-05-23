//! Physical memory map of Raspberry Pi 4B.
//!
//! This file is referenced by mkconst tool.

/// Available DRAM regions.
pub const drams = [_]Range{
    // 960 MiB
    .{
        .start = 0x0000_0000,
        .end = 0x3C00_0000,
    },

    // This gap is reserved for VideoCore in QEMU-emulated raspi4b. //

    // 1 GiB
    .{
        .start = 0x4000_0000,
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
    .start = kernel - 0x10_0000,
    .end = kernel,
};

/// Physical load address of the kernel
pub const kernel = 0x0040_0000;

comptime {
    if (loader >= kernel) {
        @compileError("Condition not met: loader < kernel");
    }
    if (kernel >= drams[0].end) {
        @compileError("Condition not met: kernel < drams[0].end");
    }
}

// =============================================================
// CPU
// =============================================================

/// Physical address of CPU spin table.
///
/// Each CPU has 8 bytes of entry.
pub const cpu_spintable = 0xD8;

// =============================================================
// Peripherals
// =============================================================

/// Base address of peripheral registers.
pub const peri_base = 0xFE00_0000;

/// DMA controller.
pub const dma = Range{
    .start = peri_base + 0x0000_7000,
    .end = peri_base + 0x0000_8000,
};

/// ARM-to-VideoCore Mailbox.
pub const mbox = Range{
    .start = peri_base + 0x0000_B000,
    .end = peri_base + 0x0000_C000,
};

/// Offset of the mailbox registers within the mbox page.
pub const mbox_offset = 0x880;

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

/// GICv2 base.
pub const gic = Range{
    .start = 0xFF84_0000,
    .end = 0xFF84_4000,
};

// =============================================================
// Imports
// =============================================================

const Range = @import("common").Range;
