test "fails with EPERM when the caller is already a process group leader" {
    const ret = linux.setsid();
    try testing.expectEqual(.PERM, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
