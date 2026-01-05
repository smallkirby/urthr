//! I/O allocator interface.

/// The type erased pointer to the allocator implementation.
ptr: *anyopaque,
/// The vtable for the allocator.
vtable: *const Vtable,

pub const Error = common.mem.Error;

const Self = @This();

/// Reserved physical memory region.
pub const Resource = struct {
    /// Name of the resource.
    name: []const u8,
    /// Physical start address of the resource.
    phys: usize,
    /// Size in bytes of the resource.
    size: usize,
    /// Parent of this resource.
    ///
    /// If null, this resource is a top-level resource.
    parent: ?*Resource = null,
    /// Children of this resource.
    children: ResourceList = .{},

    /// List head.
    list_head: ResourceList.Head = .{},
};

/// Resource list type.
pub const ResourceList = InlineDoublyLinkedList(Resource, "list_head");

/// common interface for IoAllocator.
pub const Vtable = struct {
    /// Map the given physical I/O memory region into the virtual address space.
    ///
    /// Virtual address is mapped to contiguous physical address range starting from `paddr` with size `size`.
    /// Caller must ensure that the given physical address range is reserved before calling this function.
    ///
    /// This function can map the memory using any size of pages.
    ioremap: *const fn (ctx: *anyopaque, paddr: usize, size: usize) Error!usize,

    /// Reserve the given physical I/O memory region.
    reserve: *const fn (ctx: *anyopaque, name: []const u8, phys: usize, size: usize, parent: ?*Resource) Error!*Resource,
};

/// Reserve the given physical I/O memory region.
///
/// You can use `ioremap` to map the region after reserving it.
pub fn reserve(self: Self, name: []const u8, phys: usize, size: usize, parent: ?*Resource) Error!*Resource {
    return self.vtable.reserve(self.ptr, name, phys, size, parent);
}

/// Map the given physical I/O memory region into the virtual address space.
pub fn ioremap(self: Self, paddr: usize, size: usize) Error!usize {
    return self.vtable.ioremap(self.ptr, paddr, size);
}

/// Reserve the given physical I/O memory region and map it to virtual address space.
pub fn reserveAndRemap(self: Self, name: []const u8, paddr: usize, size: usize, parent: ?*Resource) Error!usize {
    // Reserve the physical memory region first.
    _ = try self.reserve(name, paddr, size, parent);

    // Then, map it to virtual address space.
    return self.ioremap(paddr, size);
}

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const InlineDoublyLinkedList = common.typing.InlineDoublyLinkedList;
