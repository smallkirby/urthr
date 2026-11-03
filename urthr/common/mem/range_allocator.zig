//! Allocator of contiguous ranges.
//!
//! This allocator does not manage any memory by itself.

pub const Error = error{
    /// No free range that satisfies the request.
    OutOfMemory,
    /// The specified range is out of the managed region.
    InvalidRegion,
};

/// Create a range allocator type that manages the any units of `size`.
pub fn RangeAllocator(comptime size: usize) type {
    return struct {
        const Self = @This();

        /// Maximum number of units.
        pub const capacity = size;

        /// Bitmap of used units.
        used: std.bit_set.Static(capacity),
        /// The number of units managed by this allocator.
        limit: usize,

        /// Create an allocator that manages `[0, limit)`.
        ///
        /// `limit` must be less than or equal to the limit of this allocator type.
        pub fn init(limit: usize) Self {
            assert(limit <= capacity);
            assert(limit != 0);

            return .{
                .used = .empty,
                .limit = limit,
            };
        }

        /// Allocate `len` contiguous units.
        ///
        /// Returns the index of the first unit.
        pub fn alloc(self: *Self, len: usize) Error!usize {
            assert(len != 0);

            var start: usize = 0;
            while (start + len <= self.limit) {
                if (self.findUsed(start, len)) |used| {
                    start = used + 1;
                    continue;
                }

                self.used.setRangeValue(.{ .start = start, .end = start + len }, true);
                return start;
            }

            return Error.OutOfMemory;
        }

        /// Free `len` contiguous units starting from `start`.
        pub fn free(self: *Self, start: usize, len: usize) void {
            assert(start + len <= self.limit);
            assert(self.findFree(start, len) == null);

            self.used.setRangeValue(.{ .start = start, .end = start + len }, false);
        }

        /// Mark `len` contiguous units starting from `start` as used.
        ///
        /// The range may overlap with the already used units.
        pub fn reserve(self: *Self, start: usize, len: usize) Error!void {
            if (start + len > self.limit) return Error.InvalidRegion;

            self.used.setRangeValue(.{ .start = start, .end = start + len }, true);
        }

        /// Get the number of used units.
        pub fn countUsed(self: *const Self) usize {
            return self.used.count();
        }

        /// Find the first used unit in the range.
        fn findUsed(self: *const Self, start: usize, len: usize) ?usize {
            for (start..start + len) |i| {
                if (self.used.isSet(i)) return i;
            } else return null;
        }

        /// Find the first free unit in the range.
        fn findFree(self: *const Self, start: usize, len: usize) ?usize {
            for (start..start + len) |i| {
                if (!self.used.isSet(i)) return i;
            } else return null;
        }
    };
}

// =============================================================
// Tests
// =============================================================

const testing = std.testing;

test "alloc is first-fit" {
    var a = RangeAllocator(16).init(16);

    try testing.expectEqual(0, try a.alloc(4));
    try testing.expectEqual(4, try a.alloc(2));
    try testing.expectEqual(6, try a.alloc(1));
    try testing.expectEqual(7, a.countUsed());
}

test "alloc fails when exhausted" {
    var a = RangeAllocator(8).init(8);

    _ = try a.alloc(5);
    try testing.expectError(Error.OutOfMemory, a.alloc(4));
    try testing.expectEqual(5, try a.alloc(3));
    try testing.expectError(Error.OutOfMemory, a.alloc(1));
}

test "alloc never exceeds the limit even if the type allows" {
    var a = RangeAllocator(16).init(6);

    try testing.expectEqual(0, try a.alloc(4));
    try testing.expectError(Error.OutOfMemory, a.alloc(3));
    try testing.expectEqual(4, try a.alloc(2));
}

test "free makes the range reusable" {
    var a = RangeAllocator(8).init(8);

    const x = try a.alloc(3);
    const y = try a.alloc(3);
    a.free(x, 3);

    try testing.expectEqual(x, try a.alloc(2));
    try testing.expectEqual(y + 3, try a.alloc(2));
}

test "alloc skips reserved ranges" {
    var a = RangeAllocator(16).init(16);

    try a.reserve(2, 3);
    try testing.expectEqual(0, try a.alloc(2));
    try testing.expectEqual(5, try a.alloc(4));
}

test "reserve allows overlapped ranges" {
    var a = RangeAllocator(16).init(16);

    try a.reserve(0, 4);
    try a.reserve(2, 4);
    try testing.expectEqual(6, a.countUsed());
}

test "reserve rejects the range out of the limit" {
    var a = RangeAllocator(16).init(8);

    try testing.expectError(Error.InvalidRegion, a.reserve(6, 3));
    try a.reserve(6, 2);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const assert = std.debug.assert;
