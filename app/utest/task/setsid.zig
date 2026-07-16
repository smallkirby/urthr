test "fails with EPERM when the caller is already a process group leader" {
    // Set myself to a process group leader.
    try testing.expectEqual(.SUCCESS, linux.errno(linux.setpgid(0, 0)));

    const ret = linux.setsid();
    try testing.expectEqual(.PERM, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
