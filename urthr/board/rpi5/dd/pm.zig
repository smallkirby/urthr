//! Power Management Block.

// =============================================================
// Module Definition
// =============================================================

var pm = mmio.Module(.{ .size = u32 }, .{
    Reg(0x1C, u32).as(.rstc),
    Reg(0x24, u32).as(.wdog),
}){};

// =============================================================

/// Set the base address of the PM.
pub fn setBase(base: usize) void {
    pm.setBase(base);
}

pub fn reset() void {
    pm.writei(.wdog, password | 10);
    pm.writei(.rstc, password | rstc_wrcfg_full_reset);
}

// =============================================================
// Registers
// =============================================================

const password = 0x5A00_0000;
const rstc_wrcfg_full_reset = 0x0000_00020;

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const mmio = common.io.mmio;
const Reg = common.io.Reg;
