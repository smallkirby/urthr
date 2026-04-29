/// Cache information.
pub const CacheInfo = struct {
    /// Total size of the cache in bytes.
    size: usize,
    /// Cache line size in bytes.
    line_size: usize,
    /// The number of ways.
    ways: usize,

    /// The number of sets.
    pub fn sets(comptime self: CacheInfo) usize {
        return self.size / (self.line_size * self.ways);
    }

    pub fn waysShift(comptime self: CacheInfo) u6 {
        return @as(u6, @intCast(std.math.log2(self.ways)));
    }

    pub fn setsShift(comptime self: CacheInfo) u6 {
        return @as(u6, @intCast(std.math.log2(self.line_size)));
    }
};

/// Clean all data cache lines in the specified cache level.
///
/// The `level` is 0-origin.
///
/// This function does not ensure the data reaches the PoC.
pub fn cleanAllDataCacheByLevel(comptime info: CacheInfo, comptime level: u3) void {
    const level_shift = 1;

    for (0..info.sets()) |set| {
        for (0..info.ways) |way| {
            const op =
                @as(u64, way) << (32 - info.waysShift()) |
                @as(u64, set) << info.setsShift() |
                @as(u64, level) << level_shift;
            asm volatile ("dc csw, %[op]"
                :
                : [op] "r" (op),
                : .{ .memory = true });
        }
    }

    asm volatile ("dsb sy");
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
