/// syscall: exit_group
pub fn sysExitGroup(code: i32) ReturnType {
    task.exit(code);
}

/// syscall: wait4
pub fn sysWait4(pid: i32, wstatus: *allowzero i32, options: WaitOptions, _: usize) ReturnType {
    const result = task.waitChild(
        pid,
        options.nohang,
    ) catch |err| switch (err) {
        error.NoChild => return .err(.child),
    } orelse return .success(0);

    if (@intFromPtr(wstatus) != 0) {
        wstatus.* = (result.exit_status & 0xff) << 8;
    }

    return .success(@intCast(result.pid));
}

const WaitOptions = packed struct(u32) {
    /// Dont't block waiting.
    nohang: bool,
    /// Report status of children.
    untraced: bool,
    /// Reserved.
    _2: u30 = 0,
};

/// syscall: clone
pub fn sysClone(flags: CloneFlags, stack: usize, parent_tidp: usize, child_tidp: usize, tls: usize) ReturnType {
    _ = parent_tidp;
    _ = child_tidp;
    _ = tls;

    if (flags.fs) urd.unimplemented("clone: share FS");
    if (flags.files) urd.unimplemented("clone: share open files");
    if (flags.sighand) urd.unimplemented("clone: share signal handlers");
    if (flags.pidfd) urd.unimplemented("clone: pidfd");
    if (flags.ptrace) urd.unimplemented("clone: ptrace");
    if (flags.parent) urd.unimplemented("clone: share parent");
    if (flags.thread) urd.unimplemented("clone: share thread group");

    if (flags.thread and !flags.sighand) return .err(.inval);
    if (flags.sighand and !flags.vm) return .err(.inval);

    const ch_flags = std.mem.zeroInit(task.CloneFlags, .{
        .vm = flags.vm,
        .suspend_parent = flags.vfork,
    });
    const child = task.clone(
        ch_flags,
        stack,
    ) catch return .err(.nomem);

    return .success(@bitCast(@as(u64, child.tgid)));
}

/// Linux compatible flags for clone syscall.
const CloneFlags = packed struct(u64) {
    /// Signal to send to the parent on child termination.
    csignal: u8,
    /// Share VM.
    vm: bool,
    /// Share FS info.
    fs: bool,
    /// Shares open files.
    files: bool,
    /// Share signal handlers and blocked signals.
    sighand: bool,
    /// A pidfd should be placed in parent.
    pidfd: bool,
    /// Continue tracing in the child.
    ptrace: bool,
    /// Suspend the parent until the child exits or calls execve.
    vfork: bool,
    /// Have the same parent as the cloner.
    parent: bool,
    /// Have the same thread group.
    thread: bool,
    /// Reserved.
    _17: u47 = 0,
};

/// syscall: execve
pub fn sysExecve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) ReturnType {
    const max_argv = 128;
    const max_envp = 128;

    // Construct argv and envp arrays.
    var args: [max_argv][]const u8 = undefined;
    var envs: [max_envp][]const u8 = undefined;

    var argc: usize = 0;
    while (argv[argc]) |arg| : (argc += 1) {
        if (argc == max_argv) {
            return .err(.toobig);
        }
        args[argc] = std.mem.span(arg);
    }
    var envc: usize = 0;
    while (envp[envc]) |env| : (envc += 1) {
        if (envc == max_envp) {
            return .err(.toobig);
        }
        envs[envc] = std.mem.span(env);
    }

    urd.task.execve(
        std.mem.span(path),
        args[0..argc],
        envs[0..envc],
    ) catch |err| return switch (err) {
        error.InvalidArgument => .err(.inval),
        error.OutOfMemory => .err(.nomem),
        error.InvalidElf, error.NotSupported => .err(.noexec),
        error.NotFound => .err(.noent),
        error.NotDirectory => .err(.notdir),
        else => .err(.inval),
    };

    unreachable;
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

/// syscall: set_tid_address
pub fn sysSetTidAddress(_: usize) ReturnType {
    return .err(.nosys);
}

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
