/// Cached TSC frequency in Hz.
var tsc_freq: ?u64 = null;

/// Get the frequency of the system counter.
pub fn getFreq() u32 {
    // Use cached value if available.
    if (tsc_freq) |freq| {
        return @intCast(freq);
    }

    // TODO: check if invariant TSC is supported.

    const ret1 = cpuid.Leaf.query(.tsc, null);
    const denom: u64 = ret1.eax;
    const numerator: u64 = ret1.ebx;
    var crystal: u64 = ret1.ecx;

    if (denom == 0 and crystal == 0) {
        // No frequency information available. Calibrate using PIT timer.
        const cal = pit.calibrateTsc(50);
        tsc_freq = cal;
        return @intCast(cal);
    }

    if (crystal == 0) {
        // Request crystal frequency from CPUID.
        const ret2 = cpuid.Leaf.query(.freq, null);
        const freq = ret2.eax;
        crystal = @as(u64, freq) * 1_000_000;
    }

    const ret: u64 = @intCast(crystal * numerator / denom);
    tsc_freq = ret;
    return @intCast(ret);
}

/// Get the current value of the system counter.
pub fn getCount() u64 {
    return am.rdtsc();
}

/// Spin-wait for the given number of nanoseconds.
pub fn spinWaitNano(_: u64) void {
    @panic("unimplemented");
}

/// Spin-wait for the given number of microseconds.
pub fn spinWaitMicro(_: u64) void {
    @panic("unimplemented");
}

/// Spin-wait for the given number of milliseconds.
pub fn spinWaitMilli(_: u64) void {
    @panic("unimplemented");
}

/// Spin-wait for the given number of nanoseconds.
fn spinWait(_: u64) void {
    @panic("unimplemented");
}

/// Non-secure EL1 Physical Timer PPI interrupt ID.
pub const ppi_intid: u16 = 30;

/// Set the timer deadline.
pub fn setDeadline(_: u32) void {
    @panic("unimplemented");
}

/// Enable the physical timer and unmask interrupts.
pub fn enable() void {
    @panic("unimplemented");
}

/// Disable the physical timer and mask interrupts.
pub fn disable() void {
    @panic("unimplemented");
}

// =============================================================
// Timer interface.
// =============================================================

const timer_vtable = Timer.Vtable{
    .getCurrent = timerGetCurrent,
};

/// Create a timer instance.
pub fn createTimer() Timer {
    @panic("unimplemented");
}

/// Get the current tick and convert it to microseconds.
fn timerGetCurrent(_: *anyopaque) u64 {
    @panic("unimplemented");
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const Timer = common.Timer;
const cpuid = @import("cpuid.zig");
const pit = @import("pit.zig");
const am = @import("asm.zig");
