//! I/O allocator interface.

/// The type erased pointer to the allocator implementation.
ptr: *anyopaque,
/// The vtable for the allocator.
vtable: *const Vtable,

pub const Error = common.mem.Error;

const Self = @This();

/// common interface for IoAllocator.
pub const Vtable = struct {
    /// Map the given physical I/O memory region into the virtual address space.
    ioremap: *const fn (ctx: *anyopaque, paddr: usize, size: usize) Error!usize,
    /// Reserve the given physical I/O memory region.
    reserve: *const fn (ctx: *anyopaque, name: []const u8, paddr: usize, size: usize) Error!void,
};

/// Reserve the given physical I/O memory region.
///
/// You can use `ioremap` to map the region after reserving it.
pub fn reserve(self: Self, name: []const u8, paddr: usize, size: usize) Error!void {
    return self.vtable.reserve(self.ptr, name, paddr, size);
}

/// Map the given physical I/O memory region into the virtual address space.
pub fn ioremap(self: Self, paddr: usize, size: usize) Error!usize {
    return self.vtable.ioremap(self.ptr, paddr, size);
}

/// Reserve the given physical I/O memory region and map it to virtual address space.
pub fn reserveAndRemap(self: Self, name: []const u8, paddr: usize, size: usize) Error!usize {
    try self.reserve(name, paddr, size);
    return self.ioremap(paddr, size);
}

// =============================================================
// Imports
// =============================================================

const common = @import("common");
