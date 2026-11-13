//! Physical memory map of QEMU RISC-V virt machine.
//!
//! This file is referenced by mkconst tool.

/// Available DRAM regions.
///
/// The MROM (Open SBI) occupies the first 2 MiB of DRAM.
pub const drams = [_]Range{
    .{
        .start = 0x8020_0000,
        .end = 0x1_0000_0000,
    },
};

// =============================================================
// Kernel
// =============================================================

/// Physical load address of the kernel image.
///
/// The MROM (Open SBI) occupies the first 2 MiB of DRAM.
pub const kernel = 0x8020_0000;

/// Physical address of the work area used by the early allocator.
pub const boot_work = 0x8400_0000;

comptime {
    if (kernel >= boot_work) {
        @compileError("Condition not met: kernel < boot_work");
    }
    if (boot_work >= drams[0].end) {
        @compileError("Condition not met: boot_work < drams[0].end");
    }
}

// =============================================================
// Peripherals
// =============================================================

/// SiFive test device.
pub const sifive_test = Range{
    .start = 0x0010_0000,
    .end = 0x0010_1000,
};

/// NS16550 UART.
pub const uart = Range{
    .start = 0x1000_0000,
    .end = 0x1000_1000,
};

// =============================================================
// Imports
// =============================================================

const Range = @import("common").Range;
