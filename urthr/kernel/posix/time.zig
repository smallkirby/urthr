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
    uaccess.putUser(Timespec, tp, ts) catch return .err(.fault);

    return .success(0);
}

/// syscall: clock_nanosleep
pub fn sysClockNanoSleep(clock: ClockType, flags: SleepFlags, rqtp: *const Timespec, rmtp: ?*Timespec) ReturnType {
    if (std.enums.tagName(@TypeOf(clock), clock) == null) {
        return .err(.inval);
    }
    const req = uaccess.getUser(
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
    const req = uaccess.getUser(
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
        uaccess.putUser(Timespec, r, .{
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

    const knew_value = uaccess.getUser(ItimerVal, new_value) catch {
        return .err(.fault);
    };
    const value_ns = knew_value.it_value.toNs() orelse return .err(.inval);
    const interval_ns = knew_value.it_interval.toNs() orelse return .err(.inval);
    const th = sched.getCurrent();
    const old = th.itimer.set(value_ns, interval_ns);

    if (old_value) |out| {
        uaccess.putUser(ItimerVal, out, .{
            .it_value = .fromNs(old.value_ns),
            .it_interval = .fromNs(old.interval_ns),
        }) catch return .err(.fault);
    }

    return .success(0);
}

/// syscall: timerfd_create
pub fn sysTimerfdCreate(clock: ClockType, flags: posix.fs.OpenFlags) ReturnType {
    if (std.enums.tagName(@TypeOf(clock), clock) == null) {
        return .err(.inval);
    }
    if (!flags.isFit(.{ .nonblock = true, .cloexec = true })) {
        return .err(.inval);
    }

    // Create a new timer object.
    const file = fs.createTimer() catch {
        return .err(.nomem);
    };
    defer file.unref();
    file.status_flags.nonblock = flags.nonblock;

    // Put the object into the fdtable.
    const fd = sched.getCurrent().fs.fdtbl.allocAt(0, file, .{
        .cloexec = flags.cloexec,
    }) catch return .err(.mfile);

    return .success(@intCast(fd));
}

/// syscall: timerfd_settime
pub fn sysTimerfdSetTime(fd: usize, flags: TimerfdFlags, new_value: *align(1) const Itimerspec, old_value: ?*align(1) Itimerspec) ReturnType {
    if (flags._reserved != 0 or flags.cancel_on_set) {
        return .err(.inval);
    }

    const knew_value = uaccess.getUser(Itimerspec, new_value) catch {
        return .err(.fault);
    };
    var new: Itimer.Value = .{
        .value_ns = knew_value.value.toNs() orelse return .err(.inval),
        .interval_ns = knew_value.interval.toNs() orelse return .err(.inval),
    };
    if (flags.abstime and new.value_ns != 0) {
        new.value_ns = @max(new.value_ns -| urd.time.getCurrentTimestamp(), 1);
    }

    const file = getFile(fd) orelse return .err(.badf);
    defer file.unref();
    const old = fs.TimerFs.setTime(file, new) catch {
        return .err(.inval);
    };

    if (old_value) |out| {
        uaccess.putUser(Itimerspec, out, .fromSetting(old)) catch {
            return .err(.fault);
        };
    }

    return .success(0);
}

/// syscall: timerfd_gettime
pub fn sysTimerfdGetTime(fd: usize, value: *align(1) Itimerspec) ReturnType {
    const file = getFile(fd) orelse return .err(.badf);
    defer file.unref();
    const cur = fs.TimerFs.getTime(file) catch return .err(.inval);

    uaccess.putUser(Itimerspec, value, .fromSetting(cur)) catch {
        return .err(.fault);
    };

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

/// Interval timer value representation.
const ItimerVal = extern struct {
    /// Next expiration time.
    it_interval: TimeVal,
    /// Current value.
    it_value: TimeVal,
};

/// Timer setting of timerfd.
const Itimerspec = extern struct {
    /// Reload interval.
    interval: Timespec,
    /// Time of the next expiration.
    value: Timespec,

    fn fromSetting(setting: Itimer.Value) Itimerspec {
        return .{
            .interval = .fromNs(setting.interval_ns),
            .value = .fromNs(setting.value_ns),
        };
    }
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

const TimerfdFlags = packed struct(u32) {
    /// Interpret the value as an absolute time.
    abstime: bool = false,
    /// Cancel the timer when the clock is set discontinuously.
    cancel_on_set: bool = false,
    /// Not used.
    _reserved: u30 = 0,
};

// =============================================================
// Helpers
// =============================================================

/// Get a file from the given file descriptor.
///
/// Caller must release the reference of the returned file.
fn getFile(fd: usize) ?*fs.File {
    return sched.getCurrent().fs.fdtbl.get(fd) catch null;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.ptime);
const urd = @import("urthr");
const sched = urd.sched;
const ReturnType = urd.syscall.ReturnType;
const posix = urd.posix;
const uaccess = urd.uaccess;
const fs = urd.fs;
const Itimer = urd.task.Itimer;
const Timespec = urd.posix.Timespec;
const TimeVal = urd.posix.Timeval;
