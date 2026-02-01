//! Physical memory map of QEMU virt machine.
//!
//! This file is referenced by mkconst tool.

/// Available DRAM regions.
pub const drams = [_]Range{
    // 2 GiB
    .{
        .start = 0x4000_0000,
        .end = 0xC000_0000,
    },
};

// =============================================================
// Kernel
// =============================================================

/// Physical load address of the bootloader.
pub const loader = 0x4008_0000;

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
pub const kernel = 0x4100_0000;

comptime {
    if (drams[0].start > loader_reserved.start) {
        @compileError("Condition not met: drams[0].start <= loader_reserved.start");
    }
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

/// GICv3 distributor
pub const gicd = Range{
    .start = 0x0800_0000,
    .end = 0x0801_0000,
};

/// GICv3 redistributor
pub const gicr = Range{
    .start = 0x080A_0000,
    .end = 0x0900_0000,
};

/// PL011 UART (debug port)
pub const pl011 = Range{
    .start = 0x0900_0000,
    .end = 0x0900_1000,
};

/// Virtio MMIO devices.
///
/// QEMU virt machine has 32 virtio-mmio devices.
pub const virtio = Range{
    .start = 0x0A00_0000,
    .end = 0x0A00_4000,
};

/// PCIe
pub const pci = Range{
    .start = 0x0040_1000_0000,
    .end = 0x0040_2000_0000,
};

// =============================================================
// Imports
// =============================================================

const Range = @import("common").Range;
