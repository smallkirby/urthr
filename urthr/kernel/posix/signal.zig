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
    if (@intFromEnum(signum) < 0 or @intFromEnum(signum) > signal.num_signals) {
        return .err(.inval);
    }

    const should_deliver = signum != .check;
    const target_signal: signal.Signal = @enumFromInt(@intFromEnum(signum));
    const sender = sched.getCurrent().group.getCredential();

    // Single process identified by TGID.
    if (pid > 0) {
        const tgid: u32 = @bitCast(pid);
        const group = urd.task.findProcess(tgid) orelse {
            return .err(.srch);
        };
        if (!hasKillPermission(sender, group.getCredential())) {
            return .err(.perm);
        }
        if (should_deliver) {
            signal.pushTo(group.getLeader(), target_signal);
        }

        return .success(0);
    }

    // Every process the caller has permission to signal.
    if (pid == -1) {
        // TODO: not implemented.
        return .err(.nosys);
    }

    // Every process in a process group.
    const pgid: u32 = if (pid == 0) sched.getCurrent().group.getPgid() else @bitCast(-pid);
    var ctx: KillPgCtx = .{
        .sender = sender,
        .signo = target_signal,
        .act = should_deliver,
        .done = false,
    };
    if (!urd.task.forEachProcess(pgid, &ctx, killProcess)) {
        return .err(.srch);
    }
    if (!ctx.done) {
        return .err(.perm);
    }

    return .success(0);
}

const KillPgCtx = struct {
    /// Credential of the sending process.
    sender: Credential,
    /// Signal to deliver.
    signo: signal.Signal,
    /// Whether to actually deliver the signal.
    act: bool,
    /// Whether at least one matching process granted permission.
    done: bool,
};

/// Deliver the signal to to a single process in the target process group.
fn killProcess(ctx: *KillPgCtx, group: *urd.task.ThreadGroup) void {
    if (!hasKillPermission(ctx.sender, group.getCredential())) {
        return;
    }

    // Mark as delivered.
    ctx.done = true;

    // Send a signal if requested.
    if (ctx.act) {
        signal.pushTo(group.getLeader(), ctx.signo);
    }
}

/// Whether the sender is allowed to send a signal to the target.
fn hasKillPermission(sender: Credential, target: Credential) bool {
    if (sender.isPrivileged()) {
        return true;
    }
    return sender.euid == target.uid or
        sender.euid == target.suid or
        sender.uid == target.uid or
        sender.uid == target.suid;
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

/// syscall: rt_sigsuspend
pub fn sysRtSigSuspend(set: *const signal.Mask, sigsetsize: usize) ReturnType {
    if (sigsetsize != @sizeOf(signal.Mask)) {
        return .err(.inval);
    }

    const th = sched.getCurrent();
    const unblockable =
        (@as(signal.Mask, 1) << (@intFromEnum(signal.Signal.kill) - 1)) |
        (@as(signal.Mask, 1) << (@intFromEnum(signal.Signal.stop) - 1));

    const saved = th.sigstate.blocked;
    th.sigstate.blocked = set.* & ~unblockable;
    signal.waitExcept(th.sigstate.blocked);
    th.sigstate.saved_mask = saved;

    return .err(.intr);
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
const Credential = urd.task.Credential;
const ReturnType = urd.syscall.ReturnType;
const Timespec = urd.posix.Timespec;
