//! BinAllocator instance.
//!
//! Implements std.mem.Allocator interface.

/// Backing page allocator.
var page_allocator: PageAllocator = undefined;
/// Heads of the chunk lists.
var list_heads: [bin_sizes.len]ChunkMetaPointer = undefined;
/// Spin lock.
var lock: SpinLock = .{};

const vtable = Allocator.VTable{
    .alloc = allocate,
    .free = free,
    .resize = resize,
    .remap = remap,
};

const bin_sizes = [_]usize{
    0x20, 0x40, 0x80, 0x100, 0x200, 0x400, 0x800,
};

comptime {
    if (bin_sizes[0] < @sizeOf(ChunkMetaNode)) {
        @compileError("The smallest bin size is smaller than the size of ChunkMetaNode");
    }
    if (bin_sizes[bin_sizes.len - 1] > common.mem.size_4kib) {
        @compileError("The largest bin size exceeds a 4KiB page size");
    }
}

/// Metadata of free chunk.
///
/// NOTE: In zig, we don't need to store the size of the in-use chunk.
const ChunkMetaNode = extern struct {
    next: ChunkMetaPointer = null,
};
const ChunkMetaPointer = ?*ChunkMetaNode;

/// Allocator interface.
pub const interface = Allocator{
    .ptr = &.{},
    .vtable = &vtable,
};

/// Initialize the BinAllocator.
pub fn init(pagea: PageAllocator) void {
    page_allocator = pagea;
    @memset(list_heads[0..list_heads.len], null);
}
/// Get the bin index for the given size.
///
/// If the size exceeds the largest bin size, return null.
fn binIndex(size: usize) ?usize {
    for (bin_sizes, 0..) |bin_size, i| {
        if (size <= bin_size) {
            return i;
        }
    }
    return null;
}

fn allocFromBin(bin_index: usize) ?[*]u8 {
    const mask = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(mask);

    if (list_heads[bin_index] == null) {
        initBinPage(bin_index) orelse return null;
    }
    return @ptrCast(pop(&list_heads[bin_index]));
}

fn freeToBin(bin_index: usize, ptr: [*]u8) void {
    const mask = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(mask);

    const chunk: *ChunkMetaNode = @ptrCast(@alignCast(ptr));
    push(&list_heads[bin_index], chunk);
}

fn initBinPage(bin_index: usize) ?void {
    const new_page = page_allocator.allocPagesV(1) catch return null;
    const bin_size = bin_sizes[bin_index];

    var i: usize = common.mem.size_4kib / bin_size - 1;
    while (true) : (i -= 1) {
        const chunk: *ChunkMetaNode = @ptrFromInt(@intFromPtr(new_page.ptr) + i * bin_size);
        push(&list_heads[bin_index], chunk);

        if (i == 0) break;
    }
}

fn push(list_head: *ChunkMetaPointer, node: *ChunkMetaNode) void {
    if (list_head.*) |next| {
        node.next = next;
        list_head.* = node;
    } else {
        list_head.* = node;
        node.next = null;
    }
}

fn pop(list_head: *ChunkMetaPointer) *ChunkMetaNode {
    if (list_head.*) |first| {
        list_head.* = first.next;
        return first;
    } else {
        @panic("BinAllocator: pop from empty list");
    }
}

fn allocate(_: *anyopaque, n: usize, log2_align: std.mem.Alignment, _: usize) ?[*]u8 {
    const ptr_align = log2_align.toByteUnits();
    const bin_index = binIndex(@max(ptr_align, n));

    if (bin_index) |index| {
        return allocFromBin(index);
    } else {
        // Requested size including alignment exceeds a 4KiB page size.
        // Zig's Allocator does not assume an align larger than a page size.
        // So we can safely ignore the alignment, ang just return for requested size.
        const num_pages = std.math.divCeil(usize, n, common.mem.size_4kib) catch {
            @panic("BinAllocator: Unexpected division.");
        };
        const ret = page_allocator.allocPagesV(num_pages) catch return null;
        return @ptrCast(ret.ptr);
    }
}

fn free(_: *anyopaque, slice: []u8, log2_align: Alignment, _: usize) void {
    const ptr_align = log2_align.toByteUnits();
    const bin_index = binIndex(@max(ptr_align, slice.len));

    if (bin_index) |index| {
        freeToBin(index, @ptrCast(slice.ptr));
    } else {
        page_allocator.freePagesV(slice);
    }
}

fn resize(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) bool {
    @panic("BinAllocator does not support resizing");
}

/// Always force reallocating a new memory region.
fn remap(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) ?[*]u8 {
    return null;
}

// =============================================================
// Tests
// =============================================================

const testing = std.testing;

const TestPageAllocator = struct {
    pub const vtable = PageAllocator.Vtable{
        .allocPages = allocPages,
        .freePages = freePages,
        .virt2phys = virt2phys,
        .phys2virt = phys2virt,
    };

    const Error = PageAllocator.Error;

    pub fn new() TestPageAllocator {
        return .{};
    }

    pub fn allocator(self: *TestPageAllocator) PageAllocator {
        return PageAllocator{
            .ptr = self,
            .vtable = &TestPageAllocator.vtable,
        };
    }

    pub fn allocPages(_: *anyopaque, num_pages: usize) Error![]align(common.mem.size_4kib) u8 {
        const ret = try std.heap.page_allocator.alloc(
            u8,
            common.mem.size_4kib * num_pages,
        );
        return @alignCast(ret);
    }

    pub fn freePages(_: *anyopaque, slice: []u8) void {
        std.heap.page_allocator.free(slice);
    }

    pub fn freePagesRaw(_: *anyopaque, _: mem.Virt, _: usize) Error!void {
        return;
    }

    pub fn virt2phys(_: *const anyopaque, addr: usize) usize {
        return addr;
    }

    pub fn phys2virt(_: *const anyopaque, addr: usize) usize {
        return addr;
    }
};

var test_page_allocator = TestPageAllocator.new();

test {
    testing.refAllDecls(@This());
}

fn getTestingAllocator() Allocator {
    init(test_page_allocator.allocator());

    return interface;
}

test "allocation order" {
    const ba = getTestingAllocator();

    // Chunks are allocated in ascending order.
    // The distance between the chunks is same as the chunk size.
    const sizes = bin_sizes;
    for (sizes) |size| {
        var prev = try ba.alloc(u8, size);
        for (0..common.mem.size_4kib / size - 1) |_| {
            const ptr = try ba.alloc(u8, size);
            try testing.expectEqual(size, @intFromPtr(ptr.ptr) - @intFromPtr(prev.ptr));
            prev = ptr;
        }
    }

    // Most recently freed chunk is allocated first.
    for (0..3) |_| _ = try ba.alloc(u8, 0x10);
    const ptr = try ba.alloc(u8, 0x10);
    for (0..3) |_| _ = try ba.alloc(u8, 0x10);
    ba.free(ptr);
    try testing.expectEqual(ptr, try ba.alloc(u8, 0x10));
}

test "allocation size" {
    const ba = getTestingAllocator();

    for (0..5000) |size| {
        const ptr = try ba.alloc(u8, size);
        try testing.expectEqual(size, ptr.len);
        ba.free(ptr);
    }
}

test "allocation exceeds page size" {
    const ba = getTestingAllocator();

    for (0..common.mem.size_4kib / 0x20 + 8) |_| {
        const ptr = try ba.alloc(u8, 0x20);
        try testing.expectEqual(0x20, ptr.len);
    }
}

test "no mitigation against double free" {
    const ba = getTestingAllocator();

    const ptr = try ba.alloc(u8, 0x20);
    ba.free(ptr);
    ba.free(ptr);
}

// ========================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const urd = @import("urthr");
const mem = urd.mem;
const SpinLock = urd.sync.SpinLock;
const common = @import("common");
const PageAllocator = common.mem.PageAllocator;
