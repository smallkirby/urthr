test "for the caller succeeds" {
    var set: linux.cpu_set_t = undefined;
    const ret = linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &set);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    // Core#0 is eligible.
    try testing.expectEqual(true, isset(&set, 0));
}

test "for the caller's own pid succeeds" {
    const pid = linux.getpid();
    var set: linux.cpu_set_t = undefined;
    const ret = linux.sched_getaffinity(pid, @sizeOf(linux.cpu_set_t), &set);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    // Core#0 is eligible.
    try testing.expectEqual(true, isset(&set, 0));
}

test "fails with EINVAL when size is zero" {
    var set: linux.cpu_set_t = undefined;
    const ret = linux.sched_getaffinity(0, 0, &set);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

// =============================================================
// Helpers
// =============================================================

inline fn isset(set: *const linux.cpu_set_t, cpu: u32) bool {
    const idx = cpu / @bitSizeOf(usize);
    const bit = cpu % @bitSizeOf(usize);
    return (set.*[idx] & (1 << bit)) != 0;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
