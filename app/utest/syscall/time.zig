comptime {
    _ = @import("time/clock_gettime.zig");
    _ = @import("time/clock_nanosleep.zig");
    _ = @import("time/setitimer.zig");
}

// Clock kind.
pub const CLOCK_REALTIME: u32 = 0;
pub const CLOCK_MONOTONIC: u32 = 1;
pub const CLOCK_INVALID: u32 = 999;

pub fn clockGetTime(clock: u32, tp: *linux.timespec) usize {
    return std.os.linux.syscall2(.clock_gettime, clock, @intFromPtr(tp));
}

pub fn clockNanoSleep(clock: u32, flags: u32, req: *const linux.timespec, rem: ?*linux.timespec) usize {
    return std.os.linux.syscall4(
        .clock_nanosleep,
        clock,
        flags,
        @intFromPtr(req),
        if (rem) |p| @intFromPtr(p) else 0,
    );
}

/// `struct timeval`
pub const Timeval = extern struct {
    sec: i64,
    usec: i64,
};

/// `struct itimerval`
pub const Itimerval = extern struct {
    it_interval: Timeval,
    it_value: Timeval,
};

pub fn setitimer(which: linux.ITIMER, new_value: *const Itimerval, old_value: ?*Itimerval) usize {
    return std.os.linux.syscall3(
        .setitimer,
        @intCast(@intFromEnum(which)),
        @intFromPtr(new_value),
        if (old_value) |p| @intFromPtr(p) else 0,
    );
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const linux = std.os.linux;
