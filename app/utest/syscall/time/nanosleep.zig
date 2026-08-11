test "fails with EINVAL when tv_nsec is out of range" {
    const req: linux.timespec = .{ .sec = 0, .nsec = std.time.ns_per_s };
    const ret = linux.nanosleep(&req, null);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "sleeps for the requested relative duration" {
    const req: linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
    var rem: linux.timespec = .{ .sec = -1, .nsec = 0 };
    const ret = linux.nanosleep(&req, &rem);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(@as(i64, 0), rem.sec);
    try testing.expectEqual(@as(u32, 0), rem.nsec);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
