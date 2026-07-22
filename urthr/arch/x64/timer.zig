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
    const freq = @as(u128, getFreq());
    const target = start + (@as(u128, ns) * freq) / 1_000_000_000;

    while (@as(u128, getCount()) < target) {
        std.atomic.spinLoopHint();
    }
}

/// Vector delivered by the local APIC when the TSC-Deadline timer fires.
pub const ppi_intid: u16 = 0x30;

/// Set the timer deadline.
pub fn setDeadline(ticks: u32) void {
    am.wrmsri(.tsc_deadline, getCount() + ticks);
}

/// Enable the local APIC timer in TSC-Deadline mode and unmask interrupts.
pub fn enable() void {
    // Check if TSC-Deadline timer mode is supported.
    const ecx = cpuid.Leaf.version_info.query(null).ecx;
    const tsc_deadline_support = (ecx & (1 << 24)) != 0;
    if (!tsc_deadline_support) {
        @panic("CPU does not support the TSC-Deadline timer mode");
    }

    // Enable the local APIC timer.
    lapic.setTimerLvt(ppi_intid, false);
}

/// Disable the local APIC timer and mask interrupts.
pub fn disable() void {
    lapic.setTimerLvt(ppi_intid, true);
    am.wrmsr(.tsc_deadline, 0);
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
const common = @import("common");
const Timer = common.Timer;
const cpuid = @import("cpuid.zig");
const pit = @import("pit.zig");
const am = @import("asm.zig");
const lapic = @import("lapic.zig");
