test "sleep" {
    const init = utest.getInit();

    for (0..3) |i| {
        try std.Io.sleep(init.io, .fromSeconds(1), .awake);
        log.info("  {d}/3", .{i + 1});
    }
}

test "fails with EINVAL for an invalid clock id" {
    const req: linux.timespec = .{ .sec = 0, .nsec = 0 };
    const ret = time.clockNanoSleep(time.CLOCK_INVALID, 0, &req, null);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "fails with EINVAL when tv_nsec is out of range" {
    const req: linux.timespec = .{ .sec = 0, .nsec = std.time.ns_per_s };
    const ret = time.clockNanoSleep(time.CLOCK_REALTIME, 0, &req, null);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "sleeps for the requested relative duration" {
    const req: linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
    var rem: linux.timespec = .{ .sec = -1, .nsec = 0 };
    const ret = time.clockNanoSleep(time.CLOCK_MONOTONIC, 0, &req, &rem);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(@as(i64, 0), rem.sec);
    try testing.expectEqual(@as(u32, 0), rem.nsec);
}

test "with TIMER_ABSTIME succeeds for a past deadline" {
    const TIMER_ABSTIME: u32 = 1;
    const req: linux.timespec = .{ .sec = 0, .nsec = 0 };
    const ret = time.clockNanoSleep(time.CLOCK_REALTIME, TIMER_ABSTIME, &req, null);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log;
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
const time = utest.time;
