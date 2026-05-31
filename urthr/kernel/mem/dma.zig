//! Implements `common.mem.DmaAllocator` interface.

const Error = mem.Error;

/// Get an DmaAllocator interface with the given offset between CPU and bus addresses.
pub fn interface(offset: usize) DmaAllocator {
    return .{
        .ptr = &.{},
        .vtable = &vtable,
        .offset = offset,
    };
}

const vtable = DmaAllocator.Vtable{
    .allocPages = allocPages,
    .freePages = freePages,
};

fn allocPages(_: *anyopaque, num_pages: usize, attr: Attribute) Error!DmaMemory {
    // Allocate physically contiguous pages.
    const pages = try mem.page.allocPagesP(num_pages);
    const phys = @intFromPtr(pages.ptr);

    // Remap the pages as the given attribute.
    const virt = try mem.phys.ioremap(phys, num_pages * mem.page_size, attr);

    return .{
        .cpu = virt,
        .bus = phys,
        .size = num_pages * mem.page_size,
    };
}

fn freePages(_: *anyopaque, memory: DmaMemory) void {
    // Unmap the virtual memory region.
    _ = mem.phys.iounmap(memory.cpu, memory.size) catch {
        @panic("DmaAllocator: Failed to unmap the memory region");
    };

    // Free the physical pages.
    const ptr: [*]u8 = @ptrFromInt(memory.bus);
    mem.page.freePagesP(ptr[0..memory.size]);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const Attribute = common.mem.Attribute;
const DmaAllocator = common.mem.DmaAllocator;
const DmaMemory = DmaAllocator.DmaMemory;
const urd = @import("urthr");
const mem = urd.mem;
