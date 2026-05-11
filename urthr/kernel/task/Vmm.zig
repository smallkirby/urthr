//! User-space virtual memory management.

const Self = @This();

pub const Error = error{
    /// The specified virtual memory range is already mapped.
    AlreadyMapped,
} ||
    common.mem.PageAllocator.Error ||
    arch.mmu.Error;

/// Page table for this task.
pgtbl: arch.mmu.PageTablePair,
/// Tree of virtual memory areas.
tree: VmTree = .{},
/// Program break.
brk: usize = 0,
/// Next candidate address for anonymous mmap.
mmap_hint: usize = mmap_base,

/// Base virtual address for anonymous mmap allocations.
const mmap_base: usize = 0x0000_0040_0000_0000;

/// Create a new instance.
pub fn new(allocator: Allocator, pgtbl: arch.mmu.PageTablePair) Allocator.Error!*Self {
    rtt.expectEqual(null, pgtbl.l0);

    const vmm = try allocator.create(Self);
    errdefer allocator.destroy(vmm);

    const upgtbl = arch.mmu.createPageTable(
        urd.mem.getPageAllocator(),
    ) catch return error.OutOfMemory;

    vmm.* = .{
        .pgtbl = .{
            .l0 = upgtbl,
            .l1 = pgtbl.l1,
        },
    };

    return vmm;
}

/// Deinitialize this instance and free all resources.
pub fn deinit(self: *Self, allocator: Allocator) void {
    allocator.destroy(self);

    // TODO: free all virtual memory areas and unmap all pages.
    urd.unimplemented("Vmm.deinit");
}

/// Maps the given user-space virtual address.
///
/// Returns a user slice to the mapped memory.
///
/// All pages are mapped using 4KiB pages.
/// The given address and size must be page-aligned.
pub fn map(self: *Self, vaddr: usize, size: usize, perm: Permission) Error![]u8 {
    rtt.expectEqual(0, vaddr % urd.mem.page_size);
    rtt.expectEqual(0, size % urd.mem.page_size);

    const pallocator = urd.mem.getPageAllocator();
    const gallocator = urd.mem.getGeneralAllocator();

    // Check if the given virtual memory range is already mapped.
    if (self.tree.lowerBound(vaddr)) |node| {
        if (node.container().start < vaddr + size) {
            return Error.AlreadyMapped;
        }
    }

    // Allocate physical pages.
    for (0..size / urd.mem.page_size) |i| {
        const page = try pallocator.allocPagesP(1);
        errdefer pallocator.freePagesP(page);

        // Map the pages to the given virtual address.
        const va = vaddr + i * urd.mem.page_size;
        try arch.mmu.map4kb(self.pgtbl, .{
            .va = va,
            .pa = @intFromPtr(page.ptr),
            .size = size,
            .perm = perm,
            .attr = .normal,
        }, .{ .exact = true }, pallocator);
        errdefer arch.mmu.unmap4kb(
            self.pgtbl,
            va,
            urd.mem.page_size,
            pallocator,
        ) catch unreachable;
    }

    // Create a virtual memory area and insert it into the tree.
    // TODO: merge adjacent areas with the same permissions.
    const vma = try gallocator.create(VmArea);
    errdefer gallocator.destroy(vma);
    vma.* = .{
        .start = vaddr,
        .size = size,
        .perm = perm,
    };
    self.tree.insert(vma);

    return @as([*]u8, @ptrFromInt(vaddr))[0..size];
}

/// Maps an anonymous region, choosing the virtual address automatically.
///
/// Returns the chosen virtual address.
pub fn mapAnon(self: *Self, size: usize, perm: Permission) Error!usize {
    rtt.expectEqual(0, size % urd.mem.page_size);

    const va = self.findFreeRegion(self.mmap_hint, size);
    _ = try self.map(va, size, perm);
    self.mmap_hint = va + size;

    return va;
}

/// Changes permissions for an existing virtual memory range.
///
/// The given address and size must be page-aligned and backed by existing mappings.
pub fn remap(self: *Self, vaddr: usize, size: usize, perm: Permission) Error!void {
    rtt.expectEqual(0, vaddr % urd.mem.page_size);
    rtt.expectEqual(0, size % urd.mem.page_size);

    try arch.mmu.remap4kb(
        self.pgtbl,
        vaddr,
        size,
        perm,
        urd.mem.getPageAllocator(),
    );
}

/// Extend the program break to the given address.
///
/// Returns the new program break address after extension.
///
/// If the given address is less than the current program break, this function does nothing.
pub fn extendProgramBreak(self: *Self, addr: usize) Error!usize {
    rtt.expectEqual(0, addr % urd.mem.page_size);

    if (addr <= self.brk) {
        return self.brk;
    }

    _ = try self.map(self.brk, addr - self.brk, .rw);
    self.brk = addr;

    return self.brk;
}

// =============================================================
// Internals
// =============================================================

/// Find the first free virtual address region of the given size starting from the given address.
fn findFreeRegion(self: *Self, start: usize, size: usize) usize {
    var candidate = start;
    var it = self.tree.iterator();
    while (it.next()) |node| {
        const vma = node.container();
        if (vma.start + vma.size <= candidate) continue;
        if (vma.start >= candidate + size) break;
        candidate = vma.start + vma.size;
    }
    return candidate;
}

/// RB tree type of VmArea.
const VmTree = RbTree(
    VmArea,
    "_rbnode",
    VmArea.compare,
    VmArea.compareByKey,
);

/// Single contiguous virtual memory area with the same permissions.
///
/// This struct describes a single contiguous virtual memory area,
/// which may be backed by multiple non-contiguous physical pages.
const VmArea = struct {
    /// Start virtual address of the area.
    start: usize,
    /// Size in bytes of the area.
    size: usize,
    /// Permissions of the area.
    perm: Permission,

    /// Node to construct RB tree of virtual memory areas.
    _rbnode: VmTree.Node = .{},

    /// Compares two `VmArea` instances based on their start addresses.
    pub fn compare(a: *const VmArea, b: *const VmArea) std.math.Order {
        if (a.start < b.start) return .lt;
        if (a.start > b.start) return .gt;
        return .eq;
    }

    /// Compares a `VmArea` with a key based on the start address of the `VmArea`.
    pub fn compareByKey(key: usize, a: *const VmArea) std.math.Order {
        if (key < a.start) return .lt;
        if (key >= a.start + a.size) return .gt;
        return .eq;
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const rtt = common.rtt;
const RbTree = common.RbTree;
const arch = @import("arch").impl;
const urd = @import("urthr");
const Permission = common.mem.Permission;
