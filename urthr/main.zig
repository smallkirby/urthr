/// Override the standard options.
pub const std_options = std.Options{
    // Logging
    .logFn = urd.klog.log,
    .log_level = urd.klog.log_level,
};

/// Zig entry point for Urthr kernel.
///
/// This function is called in EL1 with MMU enabled.
/// UART and entire DRAM regions are identity-mapped, and kernel image is mapped at link address.
export fn kmain() callconv(.c) noreturn {
    // Early board initialization.
    board.boot();

    // Init kernel logger.
    urd.klog.set(board.getConsole());

    // Initialize exception handling.
    urd.exception.initLocal();

    // Print a boot message.
    log.info("", .{});
    log.info("Booting Urthr...", .{});

    // Halt.
    while (true) {
        asm volatile ("wfe");
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.main);
const arch = @import("arch");
const board = @import("board").impl;
const dd = @import("dd");
const urd = @import("urthr");

// Force evaluate symbols exported but not referenced in Zig.
comptime {
    _ = arch;
}
