/// Size in bytes of the saved FPU state.
const size_state = 32 * 16 + 4 * 2; // + for FPSR and FPCR
/// Required alignment of the FPU state region.
const align_state = 16;

/// Initialize the FPU state and return a pointer to it.
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
    const slice: []const u8 = ptr[0..size_state];
    allocator.free(slice);
}

/// Save the current FPU state into the given region.
pub fn saveState(state: *anyopaque) void {
    fpuSaveState(state);
}
extern fn fpuSaveState(state: *anyopaque) callconv(.c) void;

/// Restore the FPU state from the given region.
pub fn restoreState(state: *anyopaque) void {
    fpuRestoreState(state);
}
extern fn fpuRestoreState(state: *anyopaque) callconv(.c) void;

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const rtt = common.rtt;
