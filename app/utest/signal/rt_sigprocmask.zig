test "succeeds for SIG_BLOCK with an empty set" {
    const SIG_BLOCK: i32 = 0;
    var set: u64 = 0;
    const ret = linux.syscall4(
        .rt_sigprocmask,
        @bitCast(@as(isize, SIG_BLOCK)),
        @intFromPtr(&set),
        0,
        signal.mask_size,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
const signal = utest.signal;
