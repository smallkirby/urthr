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

/// `how` values for the rt_sigprocmask syscall.
pub const SIG_BLOCK: i32 = 0;
pub const SIG_UNBLOCK: i32 = 1;
pub const SIG_SETMASK: i32 = 2;

/// Raw rt_sigprocmask syscall wrapper.
pub fn sigProcMask(how: i32, set: ?*const u64, oldset: ?*u64, sigsetsize: usize) usize {
    return std.os.linux.syscall4(
        .rt_sigprocmask,
        @bitCast(@as(isize, how)),
        if (set) |p| @intFromPtr(p) else 0,
        if (oldset) |p| @intFromPtr(p) else 0,
        sigsetsize,
    );
}

/// The bit corresponding to the given signal in a signal mask.
pub fn sigBit(signo: std.os.linux.SIG) u64 {
    return @as(u64, 1) << @intCast(@intFromEnum(signo) - 1);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
