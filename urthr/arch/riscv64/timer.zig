//! RISC-V timer.

/// Interrupt ID of the supervisor timer interrupt.
///
/// Supervisor timer interrupt number.
pub const ppi_intid: u16 = 5;

/// Timer frequency of this platform in Hz.
var freq: u32 = 1;

/// Tell the timer frequency of this platform in Hz.
pub fn setFreq(freq_hz: u32) void {
    freq = freq_hz;
}

/// Get the frequency of the system counter.
pub fn getFreq() u32 {
    return freq;
}

/// Get the current value of the system counter.
pub fn getCount() u64 {
    return am.csrr(.time).value;
}

/// Spin-wait for the given number of nanoseconds.
pub fn spinWaitNano(ns: u64) void {
    spinWait(ns);
}

/// Spin-wait for the given number of microseconds.
pub fn spinWaitMicro(us: u64) void {
    spinWait(us * std.time.ns_per_us);
}

/// Spin-wait for the given number of milliseconds.
pub fn spinWaitMilli(ms: u64) void {
    spinWait(ms * std.time.ns_per_ms);
}

/// Spin-wait for the given number of nanoseconds.
fn spinWait(ns: u64) void {
    const start: u128 = getCount();
    const target = start + (@as(u128, ns) * freq) / 1_000_000_000;

    while (@as(u128, getCount()) < target) {
        std.atomic.spinLoopHint();
    }
}

/// Set the relative timer deadline.
pub fn setDeadline(ticks: u32) void {
    sbi.setTimer(getCount() + ticks) catch unreachable;
    enable();
}

/// Enable the timer.
pub fn enable() void {
    am.csrs(.sie, .{ .stie = true });
}

/// Cancel the timer deadline.
pub fn cancelDeadline() void {
    sbi.setTimer(std.math.maxInt(usize)) catch unreachable;
    am.csrc(.sie, .{ .stie = true });
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

const std = @import("std");
const Timer = @import("common").Timer;
const am = @import("asm.zig");
const sbi = @import("sbi.zig");
const regs = @import("register.zig");
