//! User-space virtual memory management.
//!
//! This struct tracks user-space virtual memory areas and their permission.
//! It does not tracks the physical pages backing the VMA.
//! If we want to get the physical pages, we have to traverse the page tables to get the backing physical address.
//!
//! Additionally, this struct also records the program memory information such as the program break and heap, which are used for implementing `brk` and `mmap` system calls.

const Self = @This();

pub const Error = error{
    /// The specified virtual memory range is already mapped.
    AlreadyMapped,
} || common.mem.PageAllocator.Error || arch.mmu.Error;

/// Page table for this task.
pgtbl: arch.mmu.PageTablePair,
/// Tree of virtual memory areas.
tree: VmTree = .{},
/// Program break.
brk: usize = 0,
/// Next candidate address for anonymous mmap.
mmap_hint: usize = mmap_base,
/// Number of tasks sharing this address space.
refcnt: usize = 1,

/// Base virtual address for anonymous mmap allocations.
const mmap_base: usize = 0x0000_0040_0000_0000;

/// Create a new instance.
pub fn new(allocator: Allocator, pgtbl: arch.mmu.PageTablePair) Allocator.Error!*Self {
    rtt.expectEqual(null, pgtbl.l0);

    const vmm = try allocator.create(Self);
    errdefer allocator.destroy(vmm);

    const upgtbl = arch.mmu.createPageTable(
        urd.mem.page,
    ) catch return error.OutOfMemory;

    vmm.* = .{
        .pgtbl = .{
            .l0 = upgtbl,
            .l1 = pgtbl.l1,
        },
    };

    return vmm;
}

/// Increment the reference count to share this address space.
pub fn ref(self: *Self) *Self {
    self.refcnt += 1;
    return self;
}

/// Deinitialize this instance and free all resources.
///
/// Resources are released only when the last reference is dropped.
pub fn deinit(self: *Self, allocator: Allocator) void {
    self.refcnt -= 1;
    if (self.refcnt > 0) return;

    // Unmap all VMAs and free their backing pages.
    while (self.tree.min()) |node| {
        const vma = node.container();
        self.unmap(vma.start, vma.size) catch {};
    }

    // TODO: free the page table pages themselves.

    allocator.destroy(self);
}

/// Clone this VM, copying all mapped pages into a new page table.
///
/// The child shares no physical pages with the parent.
pub fn clone(self: *Self, allocator: Allocator) Error!*Self {
    const child = try new(
        allocator,
        .{ .l1 = self.pgtbl.l1 },
    );
    errdefer child.deinit(allocator);

    var it = self.tree.iterator();
    while (it.next()) |node| {
        const vma = node.container();
        _ = try child.map(vma.start, vma.size, vma.perm);

        // Copy page contents from parent to child.
        var offset: usize = 0;
        while (offset < vma.size) : (offset += urd.mem.page_size) {
            const va = vma.start + offset;
            const parent_pa = arch.mmu.translateWalk(
                self.pgtbl.select(va),
                va,
                urd.mem.page,
            ) orelse continue;
            const child_pa = arch.mmu.translateWalk(
                child.pgtbl.select(va),
                va,
                urd.mem.page,
            ) orelse unreachable;

            const src = urd.mem.page.translateV(@as([*]u8, @ptrFromInt(parent_pa))[0..urd.mem.page_size]);
            const dst = urd.mem.page.translateV(@as([*]u8, @ptrFromInt(child_pa))[0..urd.mem.page_size]);
            @memcpy(dst, src);
        }
    }

    child.brk = self.brk;
    child.mmap_hint = self.mmap_hint;

    return child;
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

    // Check if the given virtual memory range is already mapped.
    if (self.tree.lowerBound(vaddr)) |node| {
        if (node.container().start < vaddr + size) {
            return Error.AlreadyMapped;
        }
    }

    // Allocate physical pages.
    for (0..size / urd.mem.page_size) |i| {
        const page = try urd.mem.page.allocPagesP(1);
        errdefer urd.mem.page.freePagesP(page);

        // Map the pages to the given virtual address.
        const va = vaddr + i * urd.mem.page_size;
        try arch.mmu.map4kb(self.pgtbl, .{
            .va = va,
            .pa = @intFromPtr(page.ptr),
            .size = size,
            .perm = perm,
            .attr = .normal,
        }, .{ .exact = true }, urd.mem.page);
        errdefer arch.mmu.unmap4kb(
            self.pgtbl,
            va,
            urd.mem.page_size,
            urd.mem.page,
        ) catch unreachable;
    }

    // Create a virtual memory area and insert it into the tree.
    const vma = try urd.mem.bin.create(VmArea);
    errdefer urd.mem.bin.destroy(vma);
    vma.* = .{
        .start = vaddr,
        .size = size,
        .perm = perm,
    };
    self.insertToVmTree(vma);

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

/// Unmap the given user-space virtual address range.
///
/// If some of the specified range is not mapped, no operation is performed for that region.
pub fn unmap(self: *Self, vaddr: usize, size: usize) Error!void {
    rtt.expectEqual(0, vaddr % urd.mem.page_size);
    rtt.expectEqual(0, size % urd.mem.page_size);

    // Free physical pages backing the range.
    for (0..size / urd.mem.page_size) |i| {
        const va = vaddr + i * urd.mem.page_size;
        const pa = arch.mmu.translateWalk(
            self.pgtbl.select(va),
            va,
            urd.mem.page,
        ) orelse {
            // If the page is not mapped, skip it.
            continue;
        };

        // Free physical pages.
        urd.mem.page.freePagesP(@as([*]u8, @ptrFromInt(pa))[0..urd.mem.page_size]);
        // Unmap the page.
        arch.mmu.unmap4kb(
            self.pgtbl,
            va,
            urd.mem.page_size,
            urd.mem.page,
        ) catch {};
    }

    // Update tree.
    try self.deleteFromVmTree(vaddr, size);
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
        urd.mem.page,
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

/// Insert a VMA into the tree.
fn insertToVmTree(self: *Self, vma: *VmArea) void {
    self.tree.insert(vma);

    // TODO: merge adjacent areas with the same permissions.
}

/// Delete a VMA from the tree.
///
/// If the specified range partially overlaps with existing VMAs, the overlapping VMAs are trimmed accordingly.
fn deleteFromVmTree(self: *Self, start: usize, size: usize) Error!void {
    const end = start + size;

    var scan = start;
    while (scan < end) {
        const node = self.tree.lowerBound(scan) orelse {
            // If there's no more VMA, we're done.
            break;
        };
        const vma = node.container();
        const vma_end = vma.start + vma.size;

        if (vma.start >= end) {
            // No more overlapping VMA, we're done.
            break;
        }

        if (vma.start < scan) {
            // Trim right of VMA.
            if (vma_end > end) {
                const right = try urd.mem.bin.create(VmArea);
                right.* = .{
                    .start = end,
                    .size = vma_end - end,
                    .perm = vma.perm,
                };
                self.tree.insert(right);
            }
            vma.size = scan - vma.start;
            scan = vma_end;
        } else if (vma_end > end) {
            // Trim left of VMA.
            self.tree.delete(vma);
            vma.start = end;
            vma.size = vma_end - end;
            self.tree.insert(vma);
            scan = end;
        } else {
            // VMA is fully contained within the unmap region.
            scan = vma_end;
            self.tree.delete(vma);
            urd.mem.bin.destroy(vma);
        }
    }
}

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
