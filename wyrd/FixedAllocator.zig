//! Fixed allocator implementation.
//!
//! Wyrd uses the first few MiB of physical memory as a buffer,
//! that is managed by this allocator.
//!
//! The Urthr kernel SHOULD NOT use the region
//! until it ensures that the region is no longer used by Wyrd.
//!

const Self = @This();

/// Region managed by the fixed allocator.
buffer: []u8,
/// Traks the next free offset in the buffer.
next: usize,

/// vtable implementing PageAllocator interface.
const vtable = PageAllocator.Vtable{
    .allocPages = allocPages,
    .freePages = freePages,
    .virt2phys = virt2phys,
    .phys2virt = phys2virt,
};

/// Initialize the allocator.
pub fn init(self: *Self, buffer: []u8) void {
    self.* = .{
        .buffer = buffer,
        .next = 0,
    };
}

/// Get the PageAllocator interface.
pub fn interface(self: *Self) PageAllocator {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

fn remaining(self: *const Self) usize {
    return self.buffer.len - self.next * page_size;
}

fn allocPages(ctx: *anyopaque, num_pages: usize) Error![]align(page_size) u8 {
    const self: *Self = @ptrCast(@alignCast(ctx));

    const size = num_pages * page_size;
    if (self.remaining() < size) {
        return Error.OutOfMemory;
    }

    const addr = self.buffer[self.next * page_size .. self.next * page_size + size];
    self.next += num_pages;

    return @alignCast(addr);
}

fn freePages(_: *anyopaque, _: []u8) void {
    @panic("FixedAllocator does not support freePages");
}

fn virt2phys(_: *const anyopaque, vaddr: usize) usize {
    return vaddr;
}

fn phys2virt(_: *const anyopaque, paddr: usize) usize {
    return paddr;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const PageAllocator = common.PageAllocator;
const Error = PageAllocator.Error;
const page_size = PageAllocator.page_size;
