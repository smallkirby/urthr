//! Thin wrapper for per-CPU data.

/// Section name where per-CPU data is placed.
pub const section = ".data..percpu";

/// Get the address of a per-CPU variable for the CPU whose per-CPU base is `base`.
pub inline fn ptrAt(base: usize, comptime v: anytype) @TypeOf(v) {
    return @ptrFromInt(base +% @intFromPtr(v));
}
