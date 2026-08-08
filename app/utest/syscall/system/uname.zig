test "succeeds and reports null-terminated fields" {
    var uts: linux.utsname = std.mem.zeroes(linux.utsname);
    const ret = linux.uname(&uts);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    try testing.expectEqualStrings("Urthr", std.mem.sliceTo(&uts.sysname, 0));
    try testing.expectEqualStrings(@tagName(builtin.cpu.arch), std.mem.sliceTo(&uts.machine, 0));

    // All fields must be null-terminated within their fixed-size buffers.
    _ = std.mem.sliceTo(&uts.nodename, 0);
    _ = std.mem.sliceTo(&uts.release, 0);
    _ = std.mem.sliceTo(&uts.version, 0);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const linux = std.os.linux;
