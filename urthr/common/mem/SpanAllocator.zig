//! Allocator of spans in a sparse address space.
//!
//! This allocator does not manage any memory by itself.

const Self = @This();

pub const Error = error{
    /// No free range that satisfies the request.
    NotAvailable,
    /// Memory allocation for internal metadata failed.
    OutOfMemory,
};

/// Managed allocator for internal metadata.
allocator: Allocator,
/// Free ranges sorted by address in ascending order.
head: ?*Range,

/// Free range of the address space.
const Range = struct {
    /// Start address of the range.
    start: usize,
    /// End address of the range. Exclusive.
    end: usize,
    /// Next range in the address order.
    next: ?*Range = null,
};

/// Create an allocator that manages the address range `[start, end)`.
pub fn init(allocator: Allocator, start: usize, end: usize) Allocator.Error!Self {
    rtt.expect(start < end);

    const range = try allocator.create(Range);
    range.* = .{ .start = start, .end = end };

    return .{
        .allocator = allocator,
        .head = range,
    };
}

/// Free all the internal metadata.
pub fn deinit(self: *Self) void {
    var cur = self.head;
    while (cur) |r| {
        cur = r.next;
        self.allocator.destroy(r);
    }
    self.head = null;
}

/// Allocate a span of `size` aligned to `alignment`.
///
/// Returns the start address of the allocated span.
pub fn alloc(self: *Self, size: usize, alignment: usize) Error!usize {
    rtt.expect(size != 0);
    rtt.expect(std.math.isPowerOfTwo(alignment));

    var link: *?*Range = &self.head;
    while (link.*) |r| : (link = &r.next) {
        const addr = std.mem.alignForward(usize, r.start, alignment);
        if (addr < r.start or addr > r.end or r.end - addr < size) {
            continue;
        }

        const addr_end = addr + size;
        if (addr == r.start and addr_end == r.end) {
            // The whole range is removed.
            link.* = r.next;
            self.allocator.destroy(r);
        } else if (addr == r.start) {
            // The start of the range is removed.
            r.start = addr_end;
        } else if (addr_end == r.end) {
            // The end of the range is removed.
            r.end = addr;
        } else {
            // The range is split into three and the second range is consumed.
            const tail = try self.allocator.create(Range);
            tail.* = .{
                .start = addr_end,
                .end = r.end,
                .next = r.next,
            };
            r.* = .{
                .start = r.start,
                .end = addr,
                .next = tail,
            };
        }

        return addr;
    }

    return Error.NotAvailable;
}

/// Free the allocated range `[addr, addr + size)`.
pub fn free(self: *Self, addr: usize, size: usize) void {
    rtt.expect(size != 0);
    const end = addr + size;

    // Find the first free range after the freed one.
    var prev: ?*Range = null;
    var next = self.head;
    while (next) |r| : (next = r.next) {
        if (r.start >= end) break;
        rtt.expect(r.end <= addr); // Must not overlap with the freed range.
        prev = r;
    }

    const merge_prev = if (prev) |p| p.end == addr else false;
    const merge_next = if (next) |n| n.start == end else false;

    if (merge_prev and merge_next) {
        prev.?.end = next.?.end;
        prev.?.next = next.?.next;
        self.allocator.destroy(next.?);
    } else if (merge_prev) {
        prev.?.end = end;
    } else if (merge_next) {
        next.?.start = addr;
    } else {
        const range = self.allocator.create(Range) catch {
            @panic("SpanAllocator: failed to allocate metadata in free()");
        };
        range.* = .{
            .start = addr,
            .end = end,
            .next = next,
        };
        if (prev) |p| p.next = range else self.head = range;
    }
}

/// Exclude `[start, end)` from the allocatable range.
///
/// Parts of the range that are already allocated are ignored.
pub fn reserve(self: *Self, start: usize, end: usize) Allocator.Error!void {
    rtt.expect(start < end);

    var link: *?*Range = &self.head;
    while (link.*) |r| {
        if (r.end <= start) {
            link = &r.next;
            continue;
        }
        if (end <= r.start) break;

        const cut_start = @max(r.start, start);
        const cut_end = @min(r.end, end);
        if (cut_start == r.start and cut_end == r.end) {
            // The whole range is removed.
            link.* = r.next;
            self.allocator.destroy(r);
        } else if (cut_start == r.start) {
            // The start of the range is removed.
            r.start = cut_end;
            link = &r.next;
        } else if (cut_end == r.end) {
            // The end of the range is removed.
            r.end = cut_start;
            link = &r.next;
        } else {
            // The range is split.
            const tail = try self.allocator.create(Range);
            tail.* = .{
                .start = cut_end,
                .end = r.end,
                .next = r.next,
            };
            r.* = .{
                .start = r.start,
                .end = cut_start,
                .next = tail,
            };
            link = &tail.next;
        }
    }
}

// =============================================================
// Tests
// =============================================================

const testing = std.testing;

/// Count the number of free ranges.
fn countRanges(self: *const Self) usize {
    var n: usize = 0;
    var cur = self.head;
    while (cur) |r| : (cur = r.next) n += 1;
    return n;
}

test "alloc and free" {
    var a = try Self.init(testing.allocator, 0x1000, 0x8000);
    defer a.deinit();

    const x = try a.alloc(0x1000, 0x1000);
    const y = try a.alloc(0x2000, 0x1000);
    try testing.expectEqual(0x1000, x);
    try testing.expectEqual(0x2000, y);

    a.free(x, 0x1000);
    try testing.expectEqual(0x1000, try a.alloc(0x1000, 0x1000));
}

test "free merges adjacent ranges" {
    var a = try Self.init(testing.allocator, 0x1000, 0x8000);
    defer a.deinit();

    const x = try a.alloc(0x1000, 0x1000);
    const y = try a.alloc(0x1000, 0x1000);
    const z = try a.alloc(0x1000, 0x1000);
    a.free(x, 0x1000);
    a.free(z, 0x1000);
    try testing.expectEqual(2, countRanges(&a));
    a.free(y, 0x1000);
    try testing.expectEqual(1, countRanges(&a));
}

test "alignment" {
    var a = try Self.init(testing.allocator, 0x1000, 0xA000);
    defer a.deinit();

    try testing.expectEqual(0x1000, try a.alloc(0x1000, 0x1000));
    try testing.expectEqual(0x4000, try a.alloc(0x1000, 0x4000));
    try testing.expectEqual(0x8000, try a.alloc(0x1000, 0x8000));
}

test "out of space" {
    var a = try Self.init(testing.allocator, 0x1000, 0x3000);
    defer a.deinit();

    _ = try a.alloc(0x2000, 0x1000);
    try testing.expectError(Error.NotAvailable, a.alloc(0x1000, 0x1000));
}

test "reserve" {
    var a = try Self.init(testing.allocator, 0x1000, 0xA000);
    defer a.deinit();

    try a.reserve(0x4000, 0x6000);
    try a.reserve(0x0, 0x2000); // trimmed
    try a.reserve(0xC000, 0xE000); // ignored
    try testing.expectEqual(2, countRanges(&a));

    // [0x2000, 0x4000), [0x6000, 0xA000)
    try testing.expectEqual(0x2000, try a.alloc(0x2000, 0x1000));
    try testing.expectEqual(0x6000, try a.alloc(0x4000, 0x1000));
    try testing.expectError(Error.NotAvailable, a.alloc(0x1000, 0x1000));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const rtt = common.rtt;
