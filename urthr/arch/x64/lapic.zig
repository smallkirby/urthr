//! Local APIC.

var lapic = mmio.Module(.{ .natural = u32 }, &.{
    .{ 0x0010, Id },
    .{ 0x00B0, Eoi },
    .{ 0x00F0, Svr },
    .{ 0x0320, LvtTimer },
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

/// Signal end-of-interrupt to the local APIC.
pub fn eoi() void {
    lapic.writez(Eoi, .{});
}

/// Configure the LVT Timer register in TSC-Deadline mode.
pub fn setTimerLvt(vector: u8, masked: bool) void {
    lapic.writez(LvtTimer, .{
        .vector = vector,
        .mask = masked,
        .timer_mode = .tsc_deadline,
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

/// EOI Register.
pub const Eoi = packed struct(u32) {
    _: u32 = 0,
};

/// LVT Timer Register.
pub const LvtTimer = packed struct(u32) {
    /// Interrupt vector number.
    vector: u8,
    /// Reserved.
    _8: u4 = 0,
    /// Delivery status.
    status: enum(u1) {
        /// No activity for this interrupt source.
        idle = 0,
        /// Interrupt from this source has been delivered to, but not yet accepted.
        pending = 1,
    } = .idle,
    /// Reserved.
    _13: u3 = 0,
    /// Interrupt mask.
    mask: bool,
    /// Timer mode.
    timer_mode: TimerMode,
    /// Reserved.
    _19: u13 = 0,
};

/// LVT Timer mode.
pub const TimerMode = enum(u2) {
    /// One-shot mode using a count-down value.
    one_shot = 0b00,
    /// Periodic mode reloading a count-down value.
    periodic = 0b01,
    /// TSC-Deadline mode using absolute target value.
    tsc_deadline = 0b10,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const mmio = common.mmio;
const am = @import("asm.zig");
