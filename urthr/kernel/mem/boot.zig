//! Boot-time fixed allocator singleton.
//!
//! Implements `PageAllocator` interface.
//!
//! Urthr uses this allocator only during early boot.
//! Urthr reserves few MiB of memory as a buffer to be managed by this allocator.
//!
//! After the system is booted and the main page allocator is ready,
//! Urthr transfers the ownership of the region to the main page allocator.
//!
//! Note that this allocator works on physical addresses only.
//!

/// Region managed by the fixed allocator.
var buffer: []u8 = undefined;
/// Tracks the next free offset in the buffer.
var next: usize = undefined;

/// vtable implementing PageAllocator interface.
const vtable = PageAllocator.Vtable{
    .allocPages = allocPages,
    .freePages = freePages,
    .virt2phys = virt2phys,
    .phys2virt = phys2virt,
};

/// Initialize the allocator.
pub fn init(buf: []u8) void {
    buffer = buf;
    next = 0;
}

/// Get the PageAllocator interface.
pub fn interface() PageAllocator {
    return .{
        .ptr = &.{},
        .vtable = &vtable,
    };
}

/// Get the region already allocated by the allocator.
pub fn getUsedRegion() Range {
    return Range{
        .start = @intFromPtr(buffer.ptr),
        .end = @intFromPtr(buffer.ptr) + next * page_size,
    };
}

fn remaining() usize {
    return buffer.len - next * page_size;
}

fn allocPages(_: *anyopaque, num_pages: usize) Error![]align(page_size) u8 {
    const size = num_pages * page_size;
    if (remaining() < size) {
        return Error.OutOfMemory;
    }

    const addr = buffer[next * page_size .. next * page_size + size];
    next += num_pages;

    return @alignCast(addr);
}

fn freePages(_: *anyopaque, _: []u8) void {
    @panic("FixedAllocator does not support freePages");
}

/// Assumes the reserved region is identity-mapped.
fn virt2phys(_: *const anyopaque, vaddr: usize) usize {
    return vaddr;
}

/// Assumes the reserved region is identity-mapped.
fn phys2virt(_: *const anyopaque, paddr: usize) usize {
    return paddr;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const PageAllocator = common.mem.PageAllocator;
const Range = common.Range;
const Error = PageAllocator.Error;
const page_size = PageAllocator.page_size;
