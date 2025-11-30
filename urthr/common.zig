//! Common library code that can be used in every module.

pub const mmio = @import("common/mmio.zig");
pub const util = @import("common/util.zig");

pub const Console = @import("common/Console.zig");
pub const PageAllocator = @import("common/PageAllocator.zig");

pub const options = @import("options");

/// Units definition.
pub const units = struct {
    pub const kib = 1024;
    pub const mib = kib * 1024;
    pub const gib = mib * 1024;
};

/// Range structure.
pub const Range = struct {
    /// Start address (inclusive).
    start: usize,
    /// End address (exclusive).
    end: usize,

    /// Size of the range.
    pub fn size(self: Range) usize {
        return self.end - self.start;
    }

    /// Check if the given address is contained in the range.
    pub fn contains(self: Range, addr: usize) bool {
        return self.start <= addr and addr < self.end;
    }
};

// =============================================================
// Tests
// =============================================================

test {
    _ = mmio;
    _ = util;
}
