pub const console = @import("kernel/console.zig");
pub const dev = @import("kernel/dev.zig");
pub const exception = @import("kernel/exception.zig");
pub const fs = @import("kernel/fs.zig");
pub const input = @import("kernel/input.zig");
pub const klog = @import("kernel/klog.zig");
pub const mem = @import("kernel/mem.zig");
pub const net = @import("kernel/net.zig");
pub const pcpu = @import("kernel/pcpu.zig");
pub const posix = @import("kernel/posix.zig");
pub const rng = @import("kernel/rng.zig");
pub const sched = @import("kernel/sched.zig");
pub const smp = @import("kernel/smp.zig");
pub const sync = @import("kernel/sync.zig");
pub const syscall = @import("kernel/syscall.zig");
pub const task = @import("kernel/task.zig");
pub const time = @import("kernel/time.zig");

pub const trace = @import("trace.zig");

pub const LogFn = klog.LogFn;
pub const SpinLock = @import("kernel/SpinLock.zig");

/// Urthr version string.
pub const version = options.version;
/// Runtime tests enabled.
pub const enable_rtt = options.enable_rtt;

/// Reached end of life.
///
/// `status` argument is used only if the board supports reset with status code.
pub fn eol(status: u8) noreturn {
    if (options.restart_on_panic) {
        console.writeUnsafe("Restarting CPU...\r\n");
        board.reset(status);
    }

    while (true) {
        arch.halt();
    }
}

/// Print an unimplemented message and reach end of life.
///
/// - `msg`: Message to print.
pub fn unimplemented(comptime msg: []const u8) noreturn {
    @branchHint(.cold);

    console.writeUnsafe("UNIMPLEMENTED: ");
    console.writeUnsafe(msg);
    console.writeUnsafe("\r\n");

    eol(4);
}

/// Assert at compile time.
pub fn comptimeAssert(comptime cond: bool, comptime msg: ?[]const u8, args: anytype) void {
    if (!cond) {
        if (msg) |m| {
            @compileError(std.fmt.comptimePrint(m, args));
        } else {
            @compileError("Assertion failed.");
        }
    }
}

// =============================================================
// Tests
// =============================================================

test {
    _ = mem;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const arch = @import("arch").impl;
const options = @import("options");
const board = @import("board").impl;
