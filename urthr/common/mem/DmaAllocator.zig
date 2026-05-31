//! DMA allocator interface.

const Self = @This();

pub const Error = mem.Error;

/// The type erased pointer to the allocator implementation.
ptr: *anyopaque,
/// The vtable for the allocator.
vtable: *const Vtable,

/// Offset added to a physical address to construct a bus address.
offset: usize,

pub const page_size = 4 * units.kib;

pub const DmaMemory = struct {
    /// Virtual address of the allocated memory region.
    cpu: usize,
    /// Bus address of the allocated memory region.
    bus: usize,
    /// Size in bytes of the allocated memory region.
    size: usize,
};

pub const Vtable = struct {
    /// Allocate a given number of physically contiguous pages with the given memory attribute.
    ///
    /// The pages must be DMA-capable.
    allocPages: *const fn (ctx: *anyopaque, num_pages: usize, attr: Attribute) Error!DmaMemory,
    /// Free the given pages.
    ///
    /// The implementation can assume that the given memory region was allocated by a previous call to `allocPages()`.
    freePages: *const fn (ctx: *anyopaque, memory: DmaMemory) void,
};

/// Allocate the given number of pages.
///
/// The allocated pages can be used for DMA operations.
pub fn allocPages(self: Self, num_pages: usize, attr: Attribute) Error!DmaMemory {
    const memory = try self.vtable.allocPages(self.ptr, num_pages, attr);

    return .{
        .cpu = memory.cpu,
        .bus = memory.bus + self.offset,
        .size = memory.size,
    };
}

/// Allocate the given size in bytes of memory.
///
/// The allocated memory can be used for DMA operations.
pub fn allocBytes(self: Self, size: usize, attr: Attribute) Error!DmaMemory {
    const aligned_size = std.mem.alignForward(usize, size, page_size);
    const num_pages = aligned_size / page_size;
    const memory = try self.allocPages(num_pages, attr);
    return .{
        .cpu = memory.cpu,
        .bus = memory.bus,
        .size = size,
    };
}

/// Free the given memory region.
///
/// `memory` must be identical to the memory returned by a previous call to `allocPages()`.
pub fn freePages(self: Self, memory: DmaMemory) void {
    rtt.expectEqual(0, memory.bus % page_size);

    self.vtable.freePages(self.ptr, .{
        .cpu = memory.cpu,
        .bus = memory.bus - self.offset,
        .size = memory.size,
    });
}

/// Free the given memory region.
///
/// `memory` must be identical to the memory returned by a previous call to `allocBytes()`.
pub fn freeBytes(self: Self, memory: DmaMemory) void {
    const size = std.mem.alignForward(usize, memory.size, page_size);
    return self.freePages(.{
        .cpu = memory.cpu,
        .bus = memory.bus,
        .size = size,
    });
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const mem = common.mem;
const units = common.units;
const Attribute = mem.Attribute;
const rtt = common.rtt;
