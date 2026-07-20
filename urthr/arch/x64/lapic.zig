//! Local APIC.

var lapic = mmio.Module(.{ .natural = u32 }, &.{
    .{ 0x0010, Id },
    .{ 0x00F0, Svr },
}){};

// =============================================================

/// Set the base address of the local APIC.
pub fn setBase(base: usize) void {
    lapic.setBase(base);
}

/// Get the base physical address of the local APIC.
pub fn getBase() usize {
    return @as(usize, am.rdmsr(.apic_base).base) << 12;
}

/// Enable the local APIC for the calling CPU.
///
/// `spurious_vector` is the vector delivered for spurious interrupts.
pub fn enable(spurious_vector: u8) void {
    var base = am.rdmsr(.apic_base);
    base.en = true;
    am.wrmsr(.apic_base, base);

    lapic.writez(Svr, .{
        .vector = spurious_vector,
        .apic_enabled = true,
    });
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

/// Spurious-Interrupt Vector Register.
pub const Svr = packed struct(u32) {
    /// Vector delivered for spurious interrupts.
    vector: u8,
    /// APIC software enable/disable.
    apic_enabled: bool = false,
    /// Focus processor checking.
    focus_checking: bool = false,
    /// Reserved.
    _10: u2 = 0,
    /// EOI-broadcast suppression.
    eoi_no_broadcast: bool = false,
    /// Reserved.
    _13: u19 = 0,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const mmio = common.mmio;
const am = @import("asm.zig");
