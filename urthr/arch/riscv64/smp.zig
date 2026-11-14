//! Handles subcore bringup sequence.

/// Hart IDs of all harts in the system.
var hart_ids: []const usize = &.{};

/// Called by a secondary core after it has been woken up.
pub fn localInit(_: usize) void {}

/// Get the virtual address that must be identity-mapped during secondary core boot.
pub fn getIdentityAddress() usize {
    @panic("TODO: SMP is not supported on riscv64 yet.");
}

/// Tell the hart IDs of this platform.
pub fn setHartIds(ids: []const usize) void {
    hart_ids = ids;
}

/// Check if the given hart ID is a known hart.
pub fn isKnownHart(hartid: usize) bool {
    return std.mem.indexOfScalar(usize, hart_ids, hartid) != null;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
