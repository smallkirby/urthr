/// The type erased pointer to the allocator implementation.
ptr: *anyopaque,
/// The vtable for the allocator.
vtable: *const Vtable,

pub const Error = error{
    /// Argument is invalid.
    InvalidArgument,
    /// Not enough memory to fulfill the request.
    OutOfMemory,
};

const Self = @This();

pub const page_size = 4 * units.kib;

/// Common interface for PageAllocator.
pub const Vtable = struct {
    allocPages: *const fn (ctx: *anyopaque, num_pages: usize) Error![]align(page_size) u8,
    freePages: *const fn (ctx: *anyopaque, slice: []u8) void,
};

/// Allocate the given number of pages from the given memory zone.
pub fn allocPages(self: Self, num_pages: usize) Error![]align(page_size) u8 {
    return self.vtable.allocPages(self.ptr, num_pages);
}

/// Free the given pages.
///
/// Allocator implementation infers the actual page sizes from the given slice.
/// Callers must ensure that the slice is a valid page-aligned memory region.
pub fn freePages(self: Self, slice: []u8) void {
    return self.vtable.freePages(self.ptr, slice);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const meta = std.meta;

const common = @import("common");
const units = common.units;
