/// syscall: exit_group
pub fn sysExitGroup(code: i32) ReturnType {
    task.exit(code);
}

/// syscall: kill
pub fn sysKill(pid: i32, signal: Signal) ReturnType {
    const cur = sched.getCurrent();
    if (signal == .check) return .success(0);

    // Resolve target process group or PID.
    const tgid: u32 = if (pid > 0)
        @bitCast(pid)
    else if (pid == 0)
        cur.pgid
    else
        return .err(.nosys); // negative pid (process group) not implemented

    // Only self-targeting is supported for now.
    if (tgid != cur.tgid and tgid != cur.pgid) {
        urd.unimplemented("kill: not self-targeting.");
    }

    switch (signal) {
        // Job-control signals with no real delivery yet: silently accept.
        .stop, .tstp, .ttin, .ttou, .cont => return .success(0),
        // Termination signals.
        .term, .int, .hup, .quit, .kill => task.exit(0),

        else => urd.unimplemented("unsupported signal,"),
    }
}

const Signal = enum(i32) {
    /// No signal is sent, but error checking is still performed.
    check = 0,
    /// Hangup detected on controlling terminal or death of controlling process.
    hup = 1,
    /// Interrupt from keyboard.
    int = 2,
    /// Quit from keyboard.
    quit = 3,
    /// Kill signal.
    kill = 9,
    /// Termination signal.
    term = 15,
    /// Child stopped or terminated.
    chld = 17,
    /// Continue if stopped.
    cont = 18,
    /// Stop process.
    stop = 19,
    /// Terminal stop signal.
    tstp = 20,
    /// Background process attempting read.
    ttin = 21,
    /// Background process attempting write.
    ttou = 22,

    _,
};

/// syscall: getpid
pub fn sysGetPid() ReturnType {
    const current = sched.getCurrent();
    return .success(@bitCast(@as(u64, current.tgid)));
}

/// syscall: getppid
pub fn sysGetPpid() ReturnType {
    const current = sched.getCurrent();
    return .success(@bitCast(@as(u64, current.ppid)));
}

/// syscall: gettid
pub fn sysGetTid() ReturnType {
    const current = sched.getCurrent();
    return .success(@bitCast(@as(u64, current.id)));
}

/// syscall: getuid
pub fn sysGetUid() ReturnType {
    return .success(0);
}

/// syscall: geteuid
pub fn sysGetEuid() ReturnType {
    return .success(0);
}

/// syscall: setpgid
pub fn sysSetPgid(pid: i32, pgid: i32) ReturnType {
    const cur = sched.getCurrent();
    if (pid != 0 and @as(u32, @bitCast(pid)) != cur.tgid) {
        return .err(.perm);
    }
    if (pgid < 0) {
        return .err(.inval);
    }
    // Session leaders cannot change their pgid.
    if (cur.tgid == cur.sid) {
        return .err(.perm);
    }
    cur.pgid = if (pgid == 0) cur.tgid else @bitCast(pgid);

    return .success(0);
}

/// syscall: getpgid
pub fn sysGetPgid(pid: i32) ReturnType {
    const cur = sched.getCurrent();
    if (pid != 0 and @as(u32, @bitCast(pid)) != cur.tgid) {
        return .err(.perm);
    }
    return .success(@intCast(cur.pgid));
}

/// syscall: setsid
pub fn sysSetsid() ReturnType {
    const cur = sched.getCurrent();
    if (cur.tgid == cur.pgid) {
        // Already a process group leader.
        return .err(.perm);
    }
    cur.sid = cur.tgid;
    cur.pgid = cur.tgid;

    return .success(@intCast(cur.sid));
}

/// syscall: getsid
pub fn sysGetsid(pid: i32) ReturnType {
    const cur = sched.getCurrent();
    if (pid != 0 and @as(u32, @bitCast(pid)) != cur.tgid) {
        return .err(.perm);
    }

    return .success(@intCast(cur.sid));
}

/// syscall: prlimit64
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
const common = @import("common");
const Permission = common.mem.Permission;
const urd = @import("urthr");
const sched = urd.sched;
const task = urd.task;
const ReturnType = urd.syscall.ReturnType;
