//! Manages references to physical pages shared by multiple mappings.
//!
//! Pages not managed by this module are implicitly owned by exactly one mapping.

/// Lowest physical address covered by this reference manager.
var base: usize = 0;
/// The number of page frame owners.
var counts: []Count = &.{};

const Count = std.atomic.Value(u32);

/// Initialize the page reference table to cover the given DRAM regions.
pub fn init(allocator: Allocator, dram_regions: []const Range) Allocator.Error!void {
    var start: usize = std.math.maxInt(usize);
    var end: usize = 0;
    for (dram_regions) |r| {
        start = @min(start, r.start);
        end = @max(end, r.end);
    }
    rtt.expect(start < end);

    base = start;
    counts = try allocator.alloc(Count, (end - start) >> page_shift);
    for (counts) |*c| c.* = .init(0);
}

/// Registers one additional owner for the physical page.
///
/// If the page is not intended to be shared, caller should not call this function.
pub fn share(pa: usize) void {
    _ = slot(pa).fetchAdd(1, .acq_rel);
}

/// Returns the number of owners of the physical page.
pub fn count(pa: usize) usize {
    return @as(usize, slot(pa).load(.acquire)) + 1;
}

/// Drops one reference to the physical page.
///
/// Returns true if the caller was the last owner of the page,
/// meaning the caller is now responsible for freeing the physical page.
pub fn unref(pa: usize) bool {
    const cnt = slot(pa);
    var old = cnt.load(.monotonic);
    while (old != 0) {
        old = cnt.cmpxchgWeak(
            old,
            old - 1,
            .acq_rel,
            .monotonic,
        ) orelse return false;
    }
    return true;
}

/// Get the counter slot for the given physical page.
fn slot(pa: usize) *Count {
    return &counts[(pa - base) >> page_shift];
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const Range = common.Range;
const rtt = common.rtt;
const urd = @import("urthr");
const page_shift = urd.mem.page_shift;
