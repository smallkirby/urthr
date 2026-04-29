//! Symmetric multiprocessing support.

/// Size in bytes of the subcore stack.
const substack_size = 5 * urd.mem.size_4kib;
/// Size in pages of the subcore stack.
const substack_pages = substack_size / urd.mem.page_size;

/// Initialize the SMP subsystem.
///
/// Wakes up all secondary cores.
pub fn init() urd.mem.Error!void {
    const allocator = urd.mem.getPageAllocator();

    try board.prepareSubcoreWakeup();
    defer board.deinitSubcoreWakeup();

    for (1..board.num_cpus) |i| {
        const stack = try allocator.allocPagesV(substack_pages);
        const sp = @intFromPtr(stack.ptr) + substack_size;

        // Wakeup the core.
        log.debug("Waking up core#{d}", .{i});
        try board.wakeSubcore(i, @intFromPtr(&ksubmain), sp);

        // Wait until the core is awake.
        log.debug("Waiting for core#{d} to wake up", .{i});
        while (waked.load(.acquire) != i) {
            std.atomic.spinLoopHint();
        }
    }
    log.info("All subcores are awake.", .{});
}

/// Counter indicating how many cores have been waked up.
var waked: std.atomic.Value(u8) = .init(0);

/// Entry point for subcores.
fn ksubmain() callconv(.c) noreturn {
    _ = waked.fetchAdd(1, .release);

    // TODO: Set exception handlers.
    // TODO: Record CPU ID and corresponding logical core ID (sequential number starting from 0).
    // TODO: Per-cpu initialization (e.g. GIC).

    // TODO: not implemented.
    while (true) asm volatile ("nop");
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.smp);
const board = @import("board").impl;
const arch = @import("arch").impl;
const common = @import("common");
const bits = common.bits;
const urd = @import("urthr");
