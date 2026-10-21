test "CPU-bound loop is accounted as user time" {
    const before = getRusage(linux.rusage.SELF);
    spinMs(50);
    const after = getRusage(linux.rusage.SELF);

    try testing.expect(after.user - before.user >= 40 * std.time.us_per_ms);
}

test "sleeping does not consume CPU time" {
    const before = getRusage(linux.rusage.SELF);
    _ = linux.nanosleep(&.{
        .sec = 0,
        .nsec = 100 * std.time.ns_per_ms,
    }, null);
    const after = getRusage(linux.rusage.SELF);

    try testing.expect((after.user + after.sys) - (before.user + before.sys) < 10 * std.time.us_per_ms);
}

test "child's CPU time is reported as RUSAGE_CHILDREN" {
    const pid = linux.fork();
    if (pid == 0) {
        spinMs(50);
        linux.exit(0);
    }
    var status: i32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);

    const children = getRusage(linux.rusage.CHILDREN);
    try testing.expect(children.user + children.sys >= 40 * std.time.us_per_ms);
}

test "times reports user time in clock ticks" {
    spinMs(50);

    var tms: [4]i64 = undefined;
    _ = linux.syscall1(.times, @intFromPtr(&tms));
    try testing.expect(tms[0] >= 4);
}

test "invalid WHO is rejected" {
    var ru: linux.rusage = undefined;
    const ret = linux.getrusage(-2, &ru);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

// =============================================================
// Helpers

const Us = struct { user: u64, sys: u64 };

/// syscall rusage wrapper.
fn getRusage(who: i32) Us {
    var ru: linux.rusage = undefined;
    _ = linux.getrusage(who, &ru);

    return .{
        .user = @as(u64, @intCast(ru.utime.sec)) * std.time.us_per_s + @as(u64, @intCast(ru.utime.usec)),
        .sys = @as(u64, @intCast(ru.stime.sec)) * std.time.us_per_s + @as(u64, @intCast(ru.stime.usec)),
    };
}

/// Spin-loop for at least the given milliseconds.
fn spinMs(ms: u64) void {
    const start = nowNs();
    while (nowNs() - start < ms * std.time.ns_per_ms) {
        var i: u32 = 0;
        while (i < 200_000) : (i += 1) std.mem.doNotOptimizeAway(i);
    }
}

/// Get the current time in nanoseconds.
fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
