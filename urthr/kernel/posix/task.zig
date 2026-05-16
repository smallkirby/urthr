/// System call: exit_group
pub fn sysExitGroup(code: i32) ReturnType {
    task.exit(code);
}

/// System call: gettid
pub fn sysGetTid() ReturnType {
    const current = sched.getCurrent();
    return .success(@bitCast(@as(u64, current.id)));
}

/// System call: getuid
pub fn sysGetUid() ReturnType {
    const current = sched.getCurrent();
    return .success(@bitCast(@as(u64, current.id)));
}

/// System call: prlimit64
pub fn sysPrlimit64(pid: i32, resource: i32, new_rlim: usize, old_rlim: usize) ReturnType {
    if (pid != 0) {
        return .err(.perm);
    }

    // TODO: implement
    _ = resource;
    _ = new_rlim;
    _ = old_rlim;

    return .success(0);
}

/// System call: clock_nanosleep
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
const common = @import("common");
const Permission = common.mem.Permission;
const urd = @import("urthr");
const sched = urd.sched;
const task = urd.task;
const ReturnType = urd.syscall.ReturnType;
