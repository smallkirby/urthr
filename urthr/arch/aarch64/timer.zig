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
