//! Page allocator interface.

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
    /// Allocate a given number of physically contiguous pages.
    ///
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

/// Allocate the given number of pages from the given memory zone.
///
/// Returns a slice representing the allocated memory region.
/// The slice points to a physical address.
pub fn allocPagesP(self: Self, num_pages: usize) Error![]align(page_size) u8 {
    return self.vtable.allocPages(self.ptr, num_pages);
}

/// Allocate the given number of pages from the given memory zone.
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

/// Free the given pages.
///
/// Allocator implementation infers the actual page sizes from the given slice.
/// Callers must ensure that the slice is a valid page-aligned memory region.
///
/// The slice points to a physical address.
pub fn freePagesP(self: Self, slice: []u8) void {
    return self.vtable.freePages(self.ptr, slice);
}

/// Free the given pages.
///
/// Allocator implementation infers the actual page sizes from the given slice.
/// Callers must ensure that the slice is a valid page-aligned memory region.
///
/// The slice points to a physical address.
pub fn freePagesV(self: Self, slice: []u8) void {
    const paddr = self.vtable.virt2phys(@intFromPtr(slice.ptr));
    const pslice: [*]u8 = @ptrFromInt(paddr);

    return self.vtable.freePages(self.ptr, pslice[0..slice.len]);
}

/// Convert the given virtual pointer to physical pointer.
pub fn translateP(self: Self, vobj: anytype) @TypeOf(vobj) {
    return switch (@typeInfo(@TypeOf(vobj))) {
        .pointer => |p| switch (p.size) {
            .one, .many, .c => {
                const paddr = self.vtable.virt2phys(self.ptr, @intFromPtr(vobj.ptr));
                return @ptrFromInt(paddr);
            },
            .slice => {
                const C = p.child;
                const paddr = self.vtable.virt2phys(self.ptr, @intFromPtr(vobj.ptr));
                return @as([*]C, @ptrFromInt(paddr))[0..vobj.len];
            },
        },
        else => @compileError("Unsupported type."),
    };
}

/// Convert the given physical slice to virtual slice.
pub fn translateV(self: Self, pobj: anytype) @TypeOf(pobj) {
    return switch (@typeInfo(@TypeOf(pobj))) {
        .pointer => |p| switch (p.size) {
            .one, .many, .c => {
                const vaddr = self.vtable.phys2virt(self.ptr, @intFromPtr(pobj.ptr));
                return @ptrFromInt(vaddr);
            },
            .slice => {
                const C = p.child;
                const vaddr = self.vtable.phys2virt(self.ptr, @intFromPtr(pobj.ptr));
                return @as([*]C, @ptrFromInt(vaddr))[0..pobj.len];
            },
        },
        else => @compileError("Unsupported type."),
    };
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const meta = std.meta;

const common = @import("common");
const units = common.units;
