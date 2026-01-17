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

/// Allocate the given number of pages.
///
/// Returns a slice representing the allocated memory region.
/// The slice points to a physical address.
pub fn allocPagesP(self: Self, num_pages: usize) Error![]align(page_size) u8 {
    return self.vtable.allocPages(self.ptr, num_pages);
}

/// Allocate the given number of pages.
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

/// Allocate the given size in bytes of memory.
///
/// Returns a slice representing the allocated memory region.
/// The slice points to a physical address.
///
/// The size is rounded up to the nearest page size.
/// The size of returned slice is equal to or greater than the requested size.
pub fn allocBytesP(self: Self, size: usize) Error![]u8 {
    const aligned_size = std.mem.alignForward(usize, size, common.mem.size_4kib);
    return self.allocPagesP(aligned_size / common.mem.size_4kib);
}

/// Allocate and construct an instance of the given type.
///
/// The object is ensured to be page-aligned.
///
/// The size of the object must be less than or equal to the page size.
pub fn create(self: Self, T: type) Error!*T {
    rtt.expect(@sizeOf(T) < common.mem.size_4kib);

    const page = try self.allocPagesV(1);
    return @ptrCast(@alignCast(page.ptr));
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
    const paddr = self.vtable.virt2phys(self.ptr, @intFromPtr(slice.ptr));
    const pslice: [*]u8 = @ptrFromInt(paddr);

    return self.vtable.freePages(self.ptr, pslice[0..slice.len]);
}

/// Free the given bytes allocated by `allocBytesP()`.
pub fn freeBytesP(self: Self, slice: []u8) void {
    return self.freePagesP(slice);
}

/// Free the given bytes allocated by `allocBytesV()`.
pub fn freeBytesV(self: Self, slice: []u8) void {
    return self.freePagesV(slice);
}

/// Destroy the given object allocated by `create()`.
pub fn destroy(self: Self, ptr: anytype) void {
    const info = @typeInfo(@TypeOf(ptr)).pointer;
    if (info.size != .one) @compileError("ptr must be a single item pointer");
    const T = info.child;
    if (@sizeOf(T) == 0) return;
    const non_const_ptr = @as([*]u8, @ptrCast(@constCast(ptr)));
    self.freePagesV(non_const_ptr[0..common.mem.size_4kib]);
}

/// Convert the given virtual pointer to physical pointer.
pub fn translateP(self: Self, vobj: anytype) @TypeOf(vobj) {
    return switch (@typeInfo(@TypeOf(vobj))) {
        .pointer => |p| switch (p.size) {
            .one, .many, .c => {
                const paddr = self.vtable.virt2phys(self.ptr, @intFromPtr(vobj));
                return @ptrFromInt(paddr);
            },
            .slice => {
                const C = p.child;
                const paddr = self.vtable.virt2phys(self.ptr, @intFromPtr(vobj.ptr));
                return @as([*]C, @ptrFromInt(paddr))[0..vobj.len];
            },
        },
        .int => return self.vtable.virt2phys(self.ptr, vobj),
        else => @compileError("Unsupported type."),
    };
}

/// Convert the given physical slice to virtual slice.
pub fn translateV(self: Self, pobj: anytype) @TypeOf(pobj) {
    return switch (@typeInfo(@TypeOf(pobj))) {
        .pointer => |p| switch (p.size) {
            .one, .many, .c => {
                const vaddr = self.vtable.phys2virt(self.ptr, @intFromPtr(pobj));
                return @ptrFromInt(vaddr);
            },
            .slice => {
                const C = p.child;
                const vaddr = self.vtable.phys2virt(self.ptr, @intFromPtr(pobj.ptr));
                return @as([*]C, @ptrFromInt(vaddr))[0..pobj.len];
            },
        },
        .int => return self.vtable.phys2virt(self.ptr, pobj),
        else => @compileError("Unsupported type."),
    };
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const meta = std.meta;
const common = @import("common");
const rtt = common.rtt;
const units = common.units;
