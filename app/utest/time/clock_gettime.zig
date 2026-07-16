test "fails with EINVAL for an invalid clock id" {
    var tp: linux.timespec = undefined;
    const ret = time.clockGetTime(time.CLOCK_INVALID, &tp);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "succeeds for CLOCK_REALTIME and CLOCK_MONOTONIC" {
    var tp: linux.timespec = undefined;
    const ret1 = time.clockGetTime(time.CLOCK_REALTIME, &tp);
    try testing.expectEqual(.SUCCESS, linux.errno(ret1));
    try testing.expect(tp.nsec < std.time.ns_per_s);

    const ret2 = time.clockGetTime(time.CLOCK_MONOTONIC, &tp);
    try testing.expectEqual(.SUCCESS, linux.errno(ret2));
    try testing.expect(tp.nsec < std.time.ns_per_s);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
const time = utest.time;
