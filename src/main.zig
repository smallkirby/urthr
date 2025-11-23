/// Override the standard options.
pub const std_options = std.Options{
    // Logging
    .logFn = urd.klog.log,
    .log_level = urd.klog.log_level,
};

export fn kinit() callconv(.c) void {
    // Early board initialization.
    board.boot();

    // Init kernel logger.
    urd.klog.set(board.getConsole());

    log.info("Booting Urthr...", .{});

    while (true) {
        asm volatile ("wfe");
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.main);
const board = @import("board").impl;
const dd = @import("dd");
const urd = @import("urthr");
