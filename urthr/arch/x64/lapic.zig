//! Local APIC.

var lapic = mmio.Module(.{ .natural = u32 }, &.{
    .{ 0x0020, Id },
    .{ 0x00B0, Eoi },
    .{ 0x00F0, Svr },
    .{ 0x0280, Esr },
    .{ 0x0300, IcrLow },
    .{ 0x0310, IcrHigh },
    .{ 0x0320, LvtTimer },
    .{ 0x0380, InitialCount },
    .{ 0x0390, CurrentCount },
    .{ 0x03E0, DivideConfig },
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

/// Get the local APIC ID of the calling CPU.
pub fn getId() u8 {
    return lapic.read(Id).id;
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

/// Configure the LVT Timer register.
pub fn setTimerLvt(vector: u8, masked: bool, mode: TimerMode) void {
    lapic.writez(LvtTimer, .{
        .vector = vector,
        .mask = masked,
        .timer_mode = mode,
    });
}

/// Set the divide value used by the timer's countdown registers.
pub fn setDivide(divide: Divide) void {
    const mode = lapic.read(LvtTimer).timer_mode;
    rtt.expect(mode == .one_shot or mode == .periodic);

    lapic.writez(DivideConfig, .{ .divide = divide });
}

/// Set the Initial Count Register.
pub fn setInitialCount(count: u32) void {
    const mode = lapic.read(LvtTimer).timer_mode;
    rtt.expect(mode == .one_shot or mode == .periodic);

    lapic.writez(InitialCount, .{ .count = count });
}

/// Read the Current Count Register.
pub fn getCurrentCount() u32 {
    const mode = lapic.read(LvtTimer).timer_mode;
    rtt.expect(mode == .one_shot or mode == .periodic);

    return lapic.read(CurrentCount).count;
}

/// Wake up a secondary core by sending IPIs.
pub fn wakeCore(dest_apic_id: u8, entry: usize) void {
    const vector: u8 = @intCast(entry >> 12);

    clearErrors();

    // INIT assert.
    lapic.writez(IcrHigh, .{
        .dest = dest_apic_id,
    });
    lapic.writez(IcrLow, .{
        .vector = 0,
        .delivery_mode = .init,
        .level = .assert,
        .trigger_mode = .level,
    });
    lapic.waitFor(IcrLow, .{ .delivery_status = .idle }, null);

    // INIT deassert.
    lapic.writez(IcrHigh, .{
        .dest = dest_apic_id,
    });
    lapic.writez(IcrLow, .{
        .vector = 0,
        .delivery_mode = .init,
        .level = .deassert,
        .trigger_mode = .level,
    });
    lapic.waitFor(IcrLow, .{ .delivery_status = .idle }, null);

    // Sleep for 10ms.
    timer.spinWaitMilli(10);
    rtt.expectEqual(std.mem.zeroes(Esr), readErrors());

    // Send two SIPIs.
    clearErrors();
    for (0..2) |_| {
        lapic.writez(IcrHigh, .{
            .dest = dest_apic_id,
        });
        lapic.writez(IcrLow, .{
            .vector = vector,
            .delivery_mode = .startup,
            .level = .assert,
        });
        lapic.waitFor(IcrLow, .{ .delivery_status = .idle }, null);

        timer.spinWaitMicro(200);
    }

    rtt.expectEqual(std.mem.zeroes(Esr), readErrors());
}

/// Clear the Error Status Register without reading it.
fn clearErrors() void {
    lapic.writez(Esr, .{});
    lapic.writez(Esr, .{});
}

/// Read the Error Status Register since the last call.
fn readErrors() Esr {
    lapic.writez(Esr, .{});
    return lapic.read(Esr);
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

/// Error Status Register.
pub const Esr = packed struct(u32) {
    /// Checksum error for a message sent on APIC bus.
    send_checksum: bool,
    /// Checksum error for a message received on APIC bus.
    rcv_checksum: bool,
    /// Message the local APIC sent was not accepted by any APIC on the APIC bus.
    send_accept: bool,
    /// Message the local APIC received was not accepted by any APIC.
    rcv_accept: bool,
    /// Attempt to send an IPI with the lowest-priority delivery mode and the APIC does not support it.
    redirectable: bool,
    /// Illegal vector in the message that it's sending.
    send_illegal: bool,
    /// Illegal vector in the message that it's receiving.
    rcv_illegal: bool,
    /// Local APIC is in xAPIC mode, and SW attempts to access a reserved register.
    illegal_reg: bool,
    /// Reserved.
    _8: u24,
};

/// Interrupt Command Register, low 32-bits.
pub const IcrLow = packed struct(u32) {
    /// The vector number of the interrupt being sent.
    vector: u8,
    /// Delivery mode.
    delivery_mode: DeliveryMode,
    /// Destination mode.
    dest_mode: enum(u1) {
        /// Uses local APIC ID.
        physical = 0,
        /// Uses 8-bit MDA (Message Destination Address).
        logical = 1,
    } = .physical,
    /// Delivery status. Read-only.
    delivery_status: enum(u1) {
        /// This local APIC has completed sending any previous IPIs.
        idle = 0,
        /// Not completed sending a previous IPIs.
        pending = 1,
    } = .idle,
    /// Reserved.
    _13: u1 = 0,
    /// Level.
    level: Level,
    /// Trigger mode.
    trigger_mode: enum(u1) {
        /// Edge-triggered.
        edge = 0,
        /// Level-triggered.
        level = 1,
    },
    /// Reserved.
    _16: u2 = 0,
    /// Destination shorthand.
    dest_shorthand: enum(u2) {
        /// Destination is specified in the destination field.
        none = 0,
        /// The issuing APIC is the one and only destination of the IPI.
        self = 1,
        /// All processors including the issuing processor.
        all_incl_self = 2,
        /// All processors excluding the issuing processor.
        all_excl_self = 3,
    },
    /// Reserved.
    _20: u12 = 0,
};

/// Interrupt Command Register, high 32-bits.
pub const IcrHigh = packed struct(u32) {
    /// Reserved.
    _0: u24 = 0,
    /// Destination APIC ID.
    dest: u8,
};

/// IPI delivery mode.
pub const DeliveryMode = enum(u3) {
    /// Delivers the interrupt specified in the vector field.
    fixed = 0b000,
    /// Delivers INIT request, which causes the target processor to perform an INIT.
    init = 0b101,
    /// Sends a special "start-up" IPI to the target processor.
    startup = 0b110,
};

/// IPI level.
pub const Level = enum(u1) {
    deassert = 0,
    assert = 1,
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

/// Initial Count Register.
pub const InitialCount = packed struct(u32) {
    count: u32,
};

/// Current Count Register.
pub const CurrentCount = packed struct(u32) {
    count: u32,
};

/// Divide Configuration Register.
pub const DivideConfig = packed struct(u32) {
    /// Divide value.
    divide: Divide,
    /// Reserved.
    _4: u28 = 0,
};

/// Timer divide value.
pub const Divide = enum(u4) {
    div2 = 0b0000,
    div4 = 0b0001,
    div8 = 0b0010,
    div16 = 0b0011,
    div32 = 0b1000,
    div64 = 0b1001,
    div128 = 0b1010,
    div1 = 0b1011,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const rtt = common.rtt;
const mmio = common.mmio;
const am = @import("asm.zig");
const timer = @import("timer.zig");
