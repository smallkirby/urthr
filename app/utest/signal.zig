comptime {
    _ = @import("signal/kill.zig");
    _ = @import("signal/rt_sigaction.zig");
    _ = @import("signal/rt_sigprocmask.zig");
    _ = @import("signal/sigaltstack.zig");
}

pub const SigAction = extern struct {
    /// Signal handler address.
    handler: usize,
    /// Flags.
    flags: u32,
    /// Padding.
    _pad: u32 = 0,
    /// Address of the sigreturn trampoline.
    restorer: usize,
    /// Signal mask to be applied when the handler is invoked.
    mask: u64,
};

/// Number of bytes of the signal mask the kernel expects.
pub const mask_size: usize = 8;

/// Raw rt_sigaction syscall wrapper.
pub fn sigAction(signum: i32, act: ?*const SigAction, oldact: ?*SigAction, sigsetsize: usize) usize {
    return std.os.linux.syscall4(
        .rt_sigaction,
        @bitCast(@as(isize, signum)),
        if (act) |p| @intFromPtr(p) else 0,
        if (oldact) |p| @intFromPtr(p) else 0,
        sigsetsize,
    );
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
