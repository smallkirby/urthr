//! Process and thread module.

pub const loader = @import("task/loader.zig");
pub const thread = @import("task/thread.zig");
pub const Vmm = @import("task/Vmm.zig");

/// The number of pages allocated for user stack.
const num_stack_pages = 5;
/// Base address of the user stack.
const stack_base = 0x7FFF_FF00_0000;

/// Enter userland by loading the specified executable.
///
/// This function does not return on success.
pub fn enterUser(filename: []const u8) !noreturn {
    const current = sched.getCurrent();
    const allocator = urd.mem.getGeneralAllocator();

    // Initialize stdout.
    const console = try urd.fs.open("/dev/console", allocator);
    defer console.unref();
    _ = try current.fs.fdtbl.set(1, console);

    // Load the executable.
    const entry = try loader.load(current, filename);

    // Prepare user stack.
    const stack = try current.vmm.map(
        stack_base,
        num_stack_pages * urd.mem.page_size,
        .rw,
    );
    @memset(stack, 0);
    const sp = stack_base + num_stack_pages * urd.mem.page_size;

    // Enter userland.
    arch.thread.enterUserland(entry, sp);
}

// =============================================================
// Imports
// =============================================================

const arch = @import("arch").impl;
const urd = @import("urthr");
const sched = urd.sched;
