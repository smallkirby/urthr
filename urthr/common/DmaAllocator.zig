//! DMA allocator interface.

/// The type erased pointer to the allocator implementation.
ptr: *anyopaque,
/// The vtable for the allocator.
vtable: *const Vtable,

/// Offset added to a physical address to construct a bus address.
offset: usize,

pub const Error = error{
    /// Argument is invalid.
    InvalidArgument,
    /// Not enough memory to fulfill the request.
    OutOfMemory,
};

const Self = @This();

pub const page_size = 4 * units.kib;

pub const Vtable = struct {
    /// Allocate a given number of physically contiguous pages.
    ///
    /// The pages must be DMA-capable.
    /// The slice points to a physical address.
    allocPages: *const fn (ctx: *anyopaque, num_pages: usize) Error![]align(page_size) u8,
    /// Free the given pages.
    ///
    /// The slice points to a physical address.
    freePages: *const fn (ctx: *anyopaque, slice: []u8) void,
    /// Convert the given virtual address to physical address.
    virt2phys: *const fn (ctx: *const anyopaque, vaddr: usize) usize,
    /// convert the given physical address to virtual address.
    phys2virt: *const fn (ctx: *const anyopaque, paddr: usize) usize,
};

/// Allocate the given number of pages.
///
/// The allocated pages can be used for DMA operations.
///
/// Returns a slice representing the allocated memory region.
/// The slice points to a virtual address.
pub fn allocPagesV(self: Self, num_pages: usize) Error![]align(page_size) u8 {
    const slice = try self.vtable.allocPages(self.ptr, num_pages);
    const ptr: [*]u8 = @ptrFromInt(self.vtable.phys2virt(
        self.ptr,
        @intFromPtr(slice.ptr),
    ));

    return @alignCast(ptr[0..slice.len]);
}

/// Allocate the given size in bytes of memory.
///
/// Returns a slice representing the allocated memory region.
/// The slice points to a virtual address.
///
/// The size is rounded up to the nearest page size.
/// The size of returned slice is equal to or greater than the requested size.
pub fn allocBytesV(self: Self, size: usize) Error![]u8 {
    const aligned_size = std.mem.alignForward(usize, size, common.mem.size_4kib);
    return self.allocPagesV(aligned_size / common.mem.size_4kib);
}

/// Allocate the given number of pages.
///
/// The allocated pages can be used for DMA operations.
///
/// Returns a slice representing the allocated memory region.
/// The slice points to a bus address.
pub fn allocPagesB(self: Self, num_pages: usize) Error![]align(page_size) u8 {
    const ptr = try self.allocPagesV(num_pages);
    return self.translateB(ptr);
}

/// Allocate the given size in bytes of memory.
///
/// Returns a slice representing the allocated memory region.
/// The slice points to a bus address.
///
/// The size is rounded up to the nearest page size.
/// The size of returned slice is equal to or greater than the requested size.
pub fn allocBytesB(self: Self, size: usize) Error![]u8 {
    const aligned_size = std.mem.alignForward(usize, size, common.mem.size_4kib);
    return self.allocPagesB(aligned_size / common.mem.size_4kib);
}

/// Free the given bytes allocated by `allocBytesV()`.
pub fn freeBytesV(self: Self, slice: []u8) void {
    return self.freePagesV(slice);
}

/// Convert the given virtual pointer to pointer in bus address space.
pub fn translateB(self: Self, vobj: anytype) @TypeOf(vobj) {
    return switch (@typeInfo(@TypeOf(vobj))) {
        .pointer => |p| switch (p.size) {
            .one, .many, .c => {
                const paddr = self.vtable.virt2phys(self.ptr, @intFromPtr(vobj));
                return @ptrFromInt(paddr);
            },
            .slice => {
                const C = p.child;
                const paddr = self.vtable.virt2phys(self.ptr, @intFromPtr(vobj.ptr));
                return @as([*]align(p.alignment) C, @ptrFromInt(paddr + self.offset))[0..vobj.len];
            },
        },
        .int => return self.vtable.virt2phys(self.ptr, vobj),
        else => @compileError("Unsupported type."),
    };
}

/// Convert the given bus address pointer to pointer in virtual address space.
pub fn translateV(self: Self, bobj: anytype) @TypeOf(bobj) {
    return switch (@typeInfo(@TypeOf(bobj))) {
        .pointer => |p| switch (p.size) {
            .one, .many, .c => {
                const paddr = @intFromPtr(bobj) - self.offset;
                const vaddr = self.vtable.phys2virt(self.ptr, paddr);
                return @ptrFromInt(vaddr);
            },
            .slice => {
                const C = p.child;
                const paddr = @intFromPtr(bobj.ptr) - self.offset;
                const vaddr = self.vtable.phys2virt(self.ptr, paddr);
                return @as([*]C, @ptrFromInt(vaddr))[0..bobj.len];
            },
        },
        .int => {
            const paddr = bobj - self.offset;
            return self.vtable.phys2virt(self.ptr, paddr);
        },
        else => @compileError("Unsupported type."),
    };
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const units = common.units;
