/// Get the frequency of the system counter.
pub fn getFreq() u32 {
    @panic("unimplemented");
}

/// Get the current value of the system counter.
pub fn getCount() u64 {
    @panic("unimplemented");
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

const common = @import("common");
const Timer = common.Timer;
const std = @import("std");
