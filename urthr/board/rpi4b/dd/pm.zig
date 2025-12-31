//! Power Management Block.

// =============================================================
// Module Definition
// =============================================================

var pm = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x1C, Rstc },
    .{ 0x24, Wdog },
}){};

// =============================================================

/// Set the base address of the PM.
pub fn setBase(base: usize) void {
    pm.setBase(base);
}

pub fn reset() void {
    pm.write(Wdog, password | 10);
    pm.write(Rstc, password | rstc_wrcfg_full_reset);
}

// =============================================================
// Registers
// =============================================================

const Rstc = packed struct(u32) {
    value: u32,
};

const Wdog = packed struct(u32) {
    value: u32,
};

const password = 0x5A00_0000;
const rstc_wrcfg_full_reset = 0x0000_00020;

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const mmio = common.mmio;
const util = common.util;
