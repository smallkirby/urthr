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
    if (rqtp.nsec >= std.time.ns_per_s) {
        return .err(.inval);
    }

    // Block until the absolute deadline.
    if (flags == .abstime) {
        const deadline_ns: u64 = @as(u64, @intCast(rqtp.sec)) * std.time.ns_per_s + rqtp.nsec;
        const now_ns = urd.time.getCurrentTimestamp();
        if (deadline_ns > now_ns) {
            const remaining_us = (deadline_ns - now_ns) / std.time.ns_per_us;
            urd.time.sleepUs(remaining_us);
        }
        return .success(0);
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

/// syscall: setitimer
pub fn sysSetItimer(which: ItimerWhich, new_value: *const ItimerVal, old_value: ?*ItimerVal) ReturnType {
    if (which != .real) {
        log.warn("Only ITIMER_REAL is supported.", .{});
        return .err(.nosys);
    }

    const th = sched.getCurrent();
    const old = urd.time.setItimer(
        th,
        new_value.it_value.toNs(),
        new_value.it_interval.toNs(),
    );

    if (old_value) |out| {
        out.* = .{
            .it_value = .fromNs(old.value_ns),
            .it_interval = .fromNs(old.interval_ns),
        };
    }

    return .success(0);
}

/// Kind of interval timer.
const ItimerWhich = enum(u32) {
    /// Decrements in real time, and delivers SIGALRM upon expiration.
    real = 0,
    /// Decrements only when the process is executing, and delivers SIGVTALRM upon expiration.
    virtual = 1,
    /// Decrements both when the process executes and when the system is executing on behalf of the process
    prof = 2,

    _,
};

/// Timer value representation.
const TimeVal = extern struct {
    /// Seconds.
    sec: i64,
    /// Microseconds.
    usec: i64,

    fn toNs(self: TimeVal) u64 {
        return @as(u64, @intCast(self.sec)) * std.time.ns_per_s + @as(u64, @intCast(self.usec)) * std.time.ns_per_us;
    }

    fn fromNs(ns: u64) TimeVal {
        return .{
            .sec = @intCast(ns / std.time.ns_per_s),
            .usec = @intCast((ns % std.time.ns_per_s) / std.time.ns_per_us),
        };
    }
};

/// Interval timer value representation.
const ItimerVal = extern struct {
    /// Next expiration time.
    it_interval: TimeVal,
    /// Current value.
    it_value: TimeVal,
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
const log = std.log.scoped(.ptime);
const urd = @import("urthr");
const sched = urd.sched;
const ReturnType = urd.syscall.ReturnType;
const Timespec = urd.posix.Timespec;
