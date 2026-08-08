test "always succeeds and returns a positive value" {
    const pid = linux.getpid();
    try testing.expect(pid > 0);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
