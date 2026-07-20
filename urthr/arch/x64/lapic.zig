//! Local APIC.

var lapic = mmio.Module(.{ .natural = u32 }, &.{
    .{ 0x0010, Id },
}){};

// =============================================================

/// Set the base address of the local APIC.
pub fn setBase(base: usize) void {
    lapic.setBase(base);
}

// =============================================================
// Registers
// =============================================================

/// Local APIC ID Register.
pub const Id = packed struct(u32) {
    /// Reserved.
    _0: u24 = 0,
    /// APIC ID.
    id: u8,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const mmio = common.mmio;
