//! Common library code that can be used in every module.

pub const bits = @import("common/bits.zig");
pub const mem = @import("common/mem.zig");
pub const mmio = @import("common/mmio.zig");
pub const rtt = @import("common/rtt.zig");
pub const typing = @import("common/typing.zig");
pub const util = @import("common/util.zig");

pub const Console = @import("common/Console.zig");
pub const IoAllocator = @import("common/IoAllocator.zig");
pub const PageAllocator = @import("common/PageAllocator.zig");
pub const RbTree = @import("common/RbTree.zig").RbTree;
pub const Timer = @import("common/Timer.zig");

pub const options = @import("options");

/// Units definition.
pub const units = struct {
    pub const kib = 1024;
    pub const mib = kib * 1024;
    pub const gib = mib * 1024;

    /// Convert bytes to KiB.
    pub fn toKib(bytes: usize) usize {
        return bytes / kib;
    }

    /// Convert bytes to MiB.
    pub fn toMib(bytes: usize) usize {
        return bytes / mib;
    }

    /// Convert bytes to GiB.
    pub fn toGib(bytes: usize) usize {
        return bytes / gib;
    }

    /// Convert bytes to KB.
    pub fn toKb(bytes: usize) usize {
        return bytes / 1000;
    }

    /// Convert bytes to MB.
    pub fn toMb(bytes: usize) usize {
        return bytes / 1_000_000;
    }

    /// Convert bytes to GB.
    pub fn toGb(bytes: usize) usize {
        return bytes / 1_000_000_000;
    }
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

/// Compile-time assertion.
pub fn comptimeAssert(comptime condition: bool, comptime message: ?[]const u8) void {
    if (!condition) {
        if (message) |msg| {
            @compileError(msg);
        } else {
            @compileError("comptime assertion failed");
        }
    }
}

// =============================================================
// Tests
// =============================================================

test {
    _ = bits;
    _ = mmio;
    _ = typing;
    _ = util;
    _ = RbTree;
}
