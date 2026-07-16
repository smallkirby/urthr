test "equals getpid for the main thread" {
    const pid = linux.getpid();
    const tid = linux.gettid();
    try testing.expectEqual(pid, tid);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
