/// syscall: clock_gettime
pub fn sysClockGetTime(clock: ClockType, tp: *Timespec) ReturnType {
    if (std.enums.tagName(@TypeOf(clock), clock) == null) {
        return .err(.inval);
    }

    const ns = urd.time.getCurrentTimestamp();
    const ts = Timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    urd.uaccess.putUser(Timespec, tp, ts) catch return .err(.fault);

    return .success(0);
}

/// syscall: clock_nanosleep
pub fn sysClockNanoSleep(clock: ClockType, flags: SleepFlags, rqtp: *const Timespec, rmtp: ?*Timespec) ReturnType {
    if (std.enums.tagName(@TypeOf(clock), clock) == null) {
        return .err(.inval);
    }
    const req = urd.uaccess.getUser(
        Timespec,
        rqtp,
    ) catch return .err(.fault);
    if (req.nsec >= std.time.ns_per_s) {
        return .err(.inval);
    }

    // Block until the absolute deadline.
    if (flags == .abstime) {
        const deadline_ns: u64 = @as(u64, @intCast(req.sec)) * std.time.ns_per_s + @as(u64, @intCast(req.nsec));
        const now_ns = urd.time.getCurrentTimestamp();
        if (deadline_ns > now_ns) {
            const remaining_us = (deadline_ns - now_ns) / std.time.ns_per_us;
            urd.time.sleepUs(remaining_us);
        }
        return .success(0);
    }

    // Block until the specified duration has passed.
    return sleepRelative(req, rmtp);
}

/// syscall: nanosleep
pub fn sysNanoSleep(rqtp: *const Timespec, rmtp: ?*Timespec) ReturnType {
    const req = urd.uaccess.getUser(
        Timespec,
        rqtp,
    ) catch return .err(.fault);
    if (req.nsec >= std.time.ns_per_s) {
        return .err(.inval);
    }

    return sleepRelative(req, rmtp);
}

/// Sleep for the relative duration specified by `req`.
fn sleepRelative(req: Timespec, rmtp: ?*Timespec) ReturnType {
    const us = req.sec * std.time.us_per_s + @divTrunc(req.nsec, std.time.ns_per_us);
    urd.time.sleepUs(@intCast(us));

    // No signals now. So remaining time is always zero.
    if (rmtp) |r| {
        urd.uaccess.putUser(Timespec, r, .{
            .sec = 0,
            .nsec = 0,
        }) catch return .err(.fault);
    }

    return .success(0);
}

/// syscall: setitimer
pub fn sysSetItimer(which: ItimerWhich, new_value: *const ItimerVal, old_value: ?*ItimerVal) ReturnType {
    if (which != .real) {
        log.warn("Only ITIMER_REAL is supported.", .{});
        return .err(.nosys);
    }

    const knew_value = urd.uaccess.getUser(
        ItimerVal,
        new_value,
    ) catch return .err(.fault);
    const th = sched.getCurrent();
    const old = urd.time.setItimer(
        th,
        knew_value.it_value.toNs(),
        knew_value.it_interval.toNs(),
    );

    if (old_value) |out| {
        urd.uaccess.putUser(ItimerVal, out, .{
            .it_value = .fromNs(old.value_ns),
            .it_interval = .fromNs(old.interval_ns),
        }) catch return .err(.fault);
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
