pub const exception = @import("kernel/exception.zig");
pub const klog = @import("kernel/klog.zig");
pub const mem = @import("kernel/mem.zig");
pub const rtt = @import("kernel/rtt.zig");

pub const LogFn = klog.LogFn;
pub const SpinLock = @import("kernel/SpinLock.zig");

/// Runtime tests enabled.
pub const enable_rtt = options.enable_rtt;

/// Reached end of life.
pub fn eol() noreturn {
    if (options.restart_on_panic) {
        var console = board.getConsole();
        _ = console.println("Restarting CPU...");

        board.reset();
    }

    while (true) {
        arch.halt();
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

const arch = @import("arch").impl;
const options = @import("common").options;
const board = @import("board").impl;
