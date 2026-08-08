test "fails with ECHILD when the caller has no children" {
    var status: u32 = undefined;
    const ret = linux.wait4(
        linux.getpid(),
        &status,
        0,
        null,
    );
    try testing.expectEqual(.CHILD, linux.errno(ret));
}

test "with WNOHANG fails with ECHILD when the caller has no children" {
    const WNOHANG: u32 = 1;
    var status: u32 = undefined;
    const ret = linux.wait4(
        linux.getpid(),
        &status,
        WNOHANG,
        null,
    );
    try testing.expectEqual(.CHILD, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
