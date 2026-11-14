/// Size in bytes of the saved FPU state.
const size_state = @sizeOf(State);
/// Required alignment of the FPU state region.
const align_state = 16;

/// Layout of the saved FPU state.
pub const State = extern struct {
    _unused: [16]u8,
};

/// Initialize the thread stack.
pub fn initState(allocator: Allocator) Allocator.Error!*anyopaque {
    const state = try allocator.alloc(u8, size_state);
    rtt.expectEqual(0, @intFromPtr(state.ptr) % align_state);
    @memset(state, 0);

    return @ptrCast(state.ptr);
}

/// De-initialize the FPU state.
///
/// Releases the region allocated for the FPU state.
pub fn deinitState(state: *anyopaque, allocator: Allocator) void {
    const ptr: [*]const u8 = @ptrCast(state);
    allocator.free(ptr[0..size_state]);
}

/// Get the size in bytes of the saved FPU state.
pub fn getStateSize() usize {
    return size_state;
}

/// Save the current FPU state into the given region.
pub fn saveState(_: *anyopaque) void {}

/// Restore the FPU state from the given region.
pub fn restoreState(_: *anyopaque) void {}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const rtt = common.rtt;
