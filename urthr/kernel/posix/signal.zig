/// System call: sigaltstack
pub fn sysSigAltStack(ss: usize, old_ss: usize) ReturnType {
    _ = ss;
    _ = old_ss;

    // TODO: implement

    return .success(0);
}

/// System call: rt_sigaction
pub fn sysRtSigAction(signum: i32, act: usize, oldact: usize, sigsetsize: usize) ReturnType {
    _ = signum;
    _ = act;
    _ = oldact;
    _ = sigsetsize;

    // TODO: implement

    return .success(0);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const urd = @import("urthr");
const sched = urd.sched;
const ReturnType = urd.syscall.ReturnType;
