/// Linux aarch64 compliant sigaction.
const SigAction = extern struct {
    /// Signal handler address.
    handler: usize,
    /// Flags.
    flags: u32,
    /// Padding.
    _pad: u32 = 0,
    /// Address of the sigreturn trampoline.
    restorer: usize,
    /// Signal mask to be applied when the handler is invoked.
    mask: signal.Mask,
};

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

/// syscall: rt_sigreturn
///
/// Restores the user context saved in the SigFrame on the user stack.
/// Called from the trampoline code inserted by kernel when returning from a signal handler.
pub fn sysRtSigReturn() ReturnType {
    urd.task.signal.sigreturn();

    // Use the saved context value as the return value to user-space.
    return .nop();
}

/// syscall: sigaltstack
pub fn sysSigAltStack(ss: usize, old_ss: usize) ReturnType {
    _ = ss;
    _ = old_ss;

    // TODO: implement

    return .success(0);
}

/// syscall: rt_sigaction
pub fn sysRtSigAction(signum: Signal, act: ?*const SigAction, oldact: ?*SigAction, sigsetsize: usize) ReturnType {
    if (sigsetsize != @sizeOf(signal.Mask)) {
        return .err(.inval);
    }
    if (@intFromEnum(signum) <= 0 or @intFromEnum(signum) > signal.num_signals) {
        return .err(.inval);
    }
    if (signum == .kill or signum == .stop) {
        // SIGKILL and SIGSTOP cannot be caught or ignored.
        return .err(.inval);
    }

    const th = sched.getCurrent();
    const bit: usize = @intCast(@intFromEnum(signum) - 1);

    // Save old action if requested.
    if (oldact) |old| {
        const cur = th.sigstate.handlers.actions[bit];
        old.* = .{
            .handler = cur.handler,
            .flags = cur.flags,
            .restorer = 0,
            .mask = cur.mask,
        };
    }

    // Set new action if requested.
    if (act) |new| {
        th.sigstate.handlers.actions[bit] = .{
            .handler = new.handler,
            .flags = new.flags,
            .mask = new.mask,
        };
    }

    return .success(0);
}

/// syscall: kill
pub fn sysKill(pid: i32, signum: Signal) ReturnType {
    if (signum == .check) {
        return .success(0);
    }
    if (@intFromEnum(signum) <= 0 or @intFromEnum(signum) > signal.num_signals) {
        return .err(.inval);
    }

    // Resolve target process group or PID.
    const cur = sched.getCurrent();
    const tgid: u32 = if (pid > 0)
        @bitCast(pid)
    else if (pid == 0)
        cur.group.getPgid()
    else
        return .err(.nosys); // negative pid (process group) not implemented

    // Only self-targeting is supported for now.
    if (tgid != cur.group.getTgid() and tgid != cur.group.getPgid()) {
        urd.unimplemented("kill: not self-targeting.");
    }

    // Deliver the signal to the target thread.
    const target = cur; // self-targeting only for now
    signal.pushTo(target, @enumFromInt(@intFromEnum(signum)));

    return .success(0);
}

const How = enum(i32) {
    /// Add `set` to the current blocked mask.
    block = 0,
    /// Remove `set` from the current blocked mask.
    unblock = 1,
    /// Replace the current blocked mask with `set`.
    setmask = 2,

    _,
};

/// syscall: rt_sigprocmask
pub fn sysRtSigProcMask(how: How, set: ?*const signal.Mask, oldset: ?*signal.Mask, sigsetsize: usize) ReturnType {
    if (sigsetsize != @sizeOf(signal.Mask)) {
        return .err(.inval);
    }

    const th = sched.getCurrent();

    // Save old blocked mask if requested.
    if (oldset) |old| {
        old.* = th.sigstate.blocked;
    }

    if (set) |new| {
        switch (how) {
            .block => th.sigstate.blocked |= new.*,
            .unblock => th.sigstate.blocked &= ~new.*,
            .setmask => th.sigstate.blocked = new.*,
            _ => return .err(.inval),
        }

        // SIGKILL and SIGSTOP cannot be blocked.
        const unblockable =
            (@as(signal.Mask, 1) << (@intFromEnum(Signal.kill) - 1)) |
            (@as(signal.Mask, 1) << (@intFromEnum(Signal.stop) - 1));
        th.sigstate.blocked &= ~unblockable;
    }

    return .success(0);
}

/// syscall: rt_sigtimedwait
pub fn sysRtSigTimedWait(set: *const signal.Mask, info: ?*SigInfo, timeout: ?*const Timespec, sigsetsize: usize) ReturnType {
    if (sigsetsize != @sizeOf(signal.Mask)) {
        return .err(.inval);
    }

    const deadline_ns: ?u64 = if (timeout) |t| blk: {
        if (t.nsec >= std.time.ns_per_s) return .err(.inval);
        const dur_ns = @as(u64, @intCast(t.sec)) * std.time.ns_per_s + t.nsec;
        break :blk urd.time.getCurrentTimestamp() + dur_ns;
    } else null;

    const signo = signal.blocksFor(
        set.*,
        deadline_ns,
    ) orelse return .err(.again);

    if (info) |i| {
        i.* = .{ .signo = @intCast(signo) };
    }

    return .success(signo);
}

/// Signal information type.
const SigInfo = extern struct {
    /// Signal number.
    signo: i32,
    /// errno value.
    errno: i32 = 0,
    /// Signal code.
    code: i32 = 0,
    /// Trap number that caused HW-generated signal.
    trapno: i32 = 0,
    /// Sending process ID.
    pid: i32 = 0,
    /// Real user ID of sending process.
    uid: i32 = 0,
    /// Exit value or signal.
    status: usize = 0,
    /// User time consumed.
    utime: u64 = 0,
    /// System time consumed.
    stime: u64 = 0,
    /// Signal value.
    value: usize = 0,
    /// POSIX.1b signal.
    int: i32 = 0,
    /// POSIX.1b signal.
    ptr: usize = 0,
    /// Timer overrun count.
    overrun: i32 = 0,
    /// Timer ID.
    timerid: i32 = 0,
    /// Memory location which caused fault.
    addr: usize = 0,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const urd = @import("urthr");
const sched = urd.sched;
const signal = urd.task.signal;
const ReturnType = urd.syscall.ReturnType;
const Timespec = urd.posix.Timespec;
