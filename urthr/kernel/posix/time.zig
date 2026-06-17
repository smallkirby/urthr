/// syscall: clock_gettime
pub fn sysClockGetTime(clock: ClockType, tp: *Timespec) ReturnType {
    if (std.enums.tagName(@TypeOf(clock), clock) == null) {
        return .err(.inval);
    }

    const ns = urd.time.getCurrentTimestamp();
    tp.sec = @intCast(ns / std.time.ns_per_s);
    tp.nsec = @intCast(ns % std.time.ns_per_s);

    return .success(0);
}

/// syscall: clock_nanosleep
pub fn sysClockNanoSleep(clock: ClockType, flags: SleepFlags, rqtp: *const Timespec, rmtp: *allowzero Timespec) ReturnType {
    if (std.enums.tagName(@TypeOf(clock), clock) == null) {
        return .err(.inval);
    }
    if (flags == .abstime) {
        return .err(.nosys); // TODO: Not implemented.
    }

    // Block until the specified duration has passed.
    const us = rqtp.sec * std.time.us_per_s + rqtp.nsec / std.time.ns_per_us;
    urd.time.sleepUs(@intCast(us));

    // No signals now. So remaining time is always zero.
    if (@intFromPtr(rmtp) != 0) {
        rmtp.sec = 0;
        rmtp.nsec = 0;
    }

    return .success(0);
}

const Timespec = extern struct {
    /// Seconds.
    sec: i64,
    /// Nanoseconds.
    nsec: u32,
};

const ClockType = enum(u32) {
    /// A settable system-wire real-time clock.
    realtime = 0,
    /// A nonsettable, monotonically increasing clock that measures time since some unspecified point in the past.
    monotonic = 1,

    _,
};

const SleepFlags = enum(u32) {
    /// Interpret the value as an absolute time as measured by the specified clock.
    abstime = 1,

    _,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const urd = @import("urthr");
const ReturnType = urd.syscall.ReturnType;
