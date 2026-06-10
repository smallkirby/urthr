/// syscall: sigaltstack
pub fn sysSigAltStack(ss: usize, old_ss: usize) ReturnType {
    _ = ss;
    _ = old_ss;

    // TODO: implement

    return .success(0);
}

/// syscall: rt_sigaction
pub fn sysRtSigAction(signum: i32, act: usize, oldact: usize, sigsetsize: usize) ReturnType {
    _ = signum;
    _ = act;
    _ = oldact;
    _ = sigsetsize;

    // TODO: implement

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
const ReturnType = urd.syscall.ReturnType;
