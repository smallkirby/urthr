test "sleep" {
    const init = utest.getInit();

    for (0..3) |i| {
        try std.Io.sleep(init.io, .fromSeconds(1), .awake);
        log.info("  {d}/3", .{i + 1});
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log;
const utest = @import("utest.zig");
