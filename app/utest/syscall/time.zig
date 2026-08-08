comptime {
    _ = @import("time/clock_gettime.zig");
    _ = @import("time/clock_nanosleep.zig");
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

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const linux = std.os.linux;
