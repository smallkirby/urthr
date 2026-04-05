pub const exception = @import("kernel/exception.zig");
pub const fs = @import("kernel/fs.zig");
pub const klog = @import("kernel/klog.zig");
pub const mem = @import("kernel/mem.zig");
pub const net = @import("kernel/net.zig");
pub const rng = @import("kernel/rng.zig");
pub const sched = @import("kernel/sched.zig");
pub const thread = @import("kernel/thread.zig");
pub const time = @import("kernel/time.zig");

pub const trace = @import("trace.zig");

pub const LogFn = klog.LogFn;
pub const SpinLock = @import("kernel/SpinLock.zig");
pub const WaitQueue = @import("kernel/WaitQueue.zig");

/// Runtime tests enabled.
pub const enable_rtt = options.enable_rtt;

/// Reached end of life.
///
/// `status` argument is used only if the board supports reset with status code.
pub fn eol(status: u8) noreturn {
    if (options.restart_on_panic) {
        var console = board.getConsole();
        _ = console.println("Restarting CPU...");

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

    var console = board.getConsole();
    _ = console.print("UNIMPLEMENTED: ");
    _ = console.println(msg);

    eol(4);
}

/// Assert at compile time.
pub fn comptimeAssert(cond: bool, comptime msg: ?[]const u8, args: anytype) void {
    if (!cond) {
        if (msg) |m| {
            @compileError(std.fmt.comptimePrint(m, args));
        } else {
            @compileError("Assertion failed.");
        }
    }
}

/// APIs for early boot stage.
pub const boot = struct {
    const BootAllocator = @import("kernel/mem/BootAllocator.zig");

    /// Early page allocator instance.
    var allocator: BootAllocator = undefined;

    /// Initialize the early page allocator.
    ///
    /// The buffer is reserved for early boot use only.
    ///
    /// This region should not overlap with the region reserved by Wyrd.
    pub fn initAllocator(start: usize, size: usize) void {
        const ptr: [*]u8 = @ptrFromInt(start);
        allocator.init(ptr[0..size]);
    }

    /// Get the early page allocator.
    pub fn getAllocator() *BootAllocator {
        return &allocator;
    }
};

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
