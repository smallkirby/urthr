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
    if (sigsetsize != 8) {
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
        const cur = th.sigstate.actions[bit];
        old.* = .{
            .handler = cur.handler,
            .flags = cur.flags,
            .restorer = 0,
            .mask = cur.mask,
        };
    }

    // Set new action if requested.
    if (act) |new| {
        th.sigstate.actions[bit] = .{
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
        cur.pgid
    else
        return .err(.nosys); // negative pid (process group) not implemented

    // Only self-targeting is supported for now.
    if (tgid != cur.tgid and tgid != cur.pgid) {
        urd.unimplemented("kill: not self-targeting.");
    }

    // Deliver the signal to the target thread.
    const target = cur; // self-targeting only for now
    const bit: u6 = @intCast(@intFromEnum(signum) - 1);
    target.sigstate.pending |= @as(signal.Mask, 1) << bit;

    return .success(0);
}

/// syscall: rt_sigprocmask
pub fn sysRtSigProcMask(how: i32, set: usize, oldset: usize, sigsetsize: usize) ReturnType {
    _ = how;
    _ = set;
    _ = oldset;
    _ = sigsetsize;

    return .err(.nosys); // TODO: Not implemented.
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const urd = @import("urthr");
const sched = urd.sched;
const signal = urd.task.signal;
const ReturnType = urd.syscall.ReturnType;
