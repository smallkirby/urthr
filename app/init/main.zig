//! Experimental init executable.

pub fn main() noreturn {
    std.posix.system.exit_group(0);
}

// =============================================================
// Panic
// =============================================================

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @branchHint(.cold);

    log.err("PANIC: {s}", .{msg});

    std.posix.system.exit_group(99);
}

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const std = @import("std");
const log = std.log.scoped(.init);
