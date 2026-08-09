test "always succeeds" {
    const ret = linux.sched_yield();
    try testing.expectEqual(0, ret);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
