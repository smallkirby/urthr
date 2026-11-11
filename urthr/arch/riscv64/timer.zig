//! RISC-V timer.

const todo = "TODO: RISC-V: timer is not supported yet";

/// Interrupt ID of the supervisor timer interrupt.
///
/// Supervisor timer interrupt number.
pub const ppi_intid: u16 = 5;

/// Get the frequency of the system counter.
pub fn getFreq() u32 {
    @panic(todo);
}

/// Get the current value of the system counter.
pub fn getCount() u64 {
    @panic(todo);
}

/// Spin-wait for the given number of nanoseconds.
pub fn spinWaitNano(_: u64) void {
    @panic(todo);
}

/// Spin-wait for the given number of microseconds.
pub fn spinWaitMicro(_: u64) void {
    @panic(todo);
}

/// Spin-wait for the given number of milliseconds.
pub fn spinWaitMilli(_: u64) void {
    @panic(todo);
}

/// Set the timer deadline.
pub fn setDeadline(_: u32) void {
    @panic(todo);
}

/// Enable the timer.
pub fn enable() void {
    @panic(todo);
}

/// Cancel the timer deadline.
pub fn cancelDeadline() void {
    @panic(todo);
}

/// Create a timer instance.
pub fn createTimer() Timer {
    @panic(todo);
}

// =============================================================
// Imports
// =============================================================

const Timer = @import("common").Timer;
