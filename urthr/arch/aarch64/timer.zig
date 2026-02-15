//! Aarch64 Generic Timer.

/// Get the frequency of the system counter.
pub fn getFreq() u32 {
    return am.mrs(.cntfrq_el0).freq;
}

/// Get the current value of the system counter.
pub fn getCount() u64 {
    return am.mrs(.cntpct_el0).value;
}

/// Spin-wait for the given number of nanoseconds.
pub fn spinWaitNano(ns: u64) void {
    spinWait(ns);
}

/// Spin-wait for the given number of microseconds.
pub fn spinWaitMicro(us: u64) void {
    spinWait(us * 1_000);
}

/// Spin-wait for the given number of milliseconds.
pub fn spinWaitMilli(ms: u64) void {
    spinWait(ms * 1_000_000);
}

/// Spin-wait for the given number of nanoseconds.
fn spinWait(ns: u64) void {
    const start = getCount();
    const freq = @as(u64, getFreq());
    const target = start + (ns * freq) / 1_000_000_000;

    while (getCount() < target) {
        std.atomic.spinLoopHint();
    }
}

/// Non-secure EL1 Physical Timer PPI interrupt ID.
pub const ppi_intid: u16 = 30;

/// Set the timer deadline.
pub fn setDeadline(ticks: u32) void {
    am.msr(.cntp_tval_el0, regs.CntpTval{
        .value = ticks,
    });
}

/// Enable the physical timer and unmask interrupts.
pub fn enable() void {
    am.msr(.cntp_ctl_el0, regs.CntpCtl{
        .enable = true,
        .imask = false,
        .istatus = false,
    });
}

/// Disable the physical timer and mask interrupts.
pub fn disable() void {
    am.msr(.cntp_ctl_el0, regs.CntpCtl{
        .enable = false,
        .imask = true,
        .istatus = false,
    });
}

// =============================================================
// Timer interface.
// =============================================================

const timer_vtable = Timer.Vtable{
    .getCurrent = timerGetCurrent,
};

/// Create a timer instance.
pub fn createTimer() Timer {
    return .{
        ._ctx = &.{},
        .vtable = timer_vtable,
    };
}

/// Get the current tick and convert it to microseconds.
fn timerGetCurrent(_: *anyopaque) u64 {
    return (getCount() * 1_000_000) / getFreq();
}

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const Timer = common.Timer;
const std = @import("std");
const am = @import("asm.zig");
const regs = @import("register.zig");
