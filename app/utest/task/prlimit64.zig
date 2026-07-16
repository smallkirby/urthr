test "for the caller (pid=0) succeeds" {
    const ret = linux.prlimit(
        0,
        .NOFILE,
        null,
        null,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
