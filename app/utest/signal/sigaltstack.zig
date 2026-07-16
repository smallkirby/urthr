test "installs an alternate signal stack" {
    var altstack_buf: [8192]u8 align(16) = undefined;
    const ss: linux.stack_t = .{
        .sp = &altstack_buf,
        .flags = 0,
        .size = altstack_buf.len,
    };

    const ret = linux.sigaltstack(&ss, null);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    // Restore the disabled state.
    const disable: linux.stack_t = .{
        .sp = &altstack_buf,
        .flags = linux.SS.DISABLE,
        .size = altstack_buf.len,
    };
    _ = linux.sigaltstack(&disable, null);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
