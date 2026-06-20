//! Manages virtual memory allocation.

pub const Error = mem.Error;

/// Spin lock on virtual address management.
var lock = SpinLock{};
/// All allocated virtual memory areas.
var area_list: VmArea.Tree = .{};
/// Free virtual memory areas available for use.
var free_list: VmArea.Tree = .{};

/// Initialize the virtual memory allocator.
///
/// Must be called before any call to the allocator functions.
pub fn init() Error!void {
    const init_area = try mem.bin.create(VmArea);
    init_area.* = .{
        .start = vmap.vmem.start,
        .end = vmap.vmem.end,
        .vmtree = .{},
    };
    free_list.insert(init_area);
}

/// Allocate a virtual memory area with the given size.
///
/// Note that allocated virtual memory is not backed by physical memory.
pub fn allocateVirtualArea(size: usize) Error!*VmArea {
    rtt.expectEqual(0, size % urd.mem.page_size);

    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    var it = free_list.iterator();
    while (it.next()) |node| {
        const free_area = node.container();
        const free_size = free_area.end - free_area.start;

        if (free_size == size) {
            free_list.delete(free_area);
            free_area.rbnode = .init;
            area_list.insert(free_area);
            return free_area;
        } else if (free_size > size) {
            const area = try mem.bin.create(VmArea);
            area.* = .{
                .start = free_area.start,
                .end = free_area.start + size,
                .vmtree = .{},
            };
            area_list.insert(area);

            // Changing the start address does not change the order of the free area in the tree.
            free_area.start += size;

            return area;
        }
    } else return Error.OutOfVirtualMemory;
}

/// Returns a virtual memory area for reuse.
///
/// The caller must ensure that all physical mappings within the area
/// have been removed before calling this function.
pub fn freeVirtualArea(area: *VmArea) void {
    rtt.expectEqual(null, area.vmtree.root);

    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    freeArea(area);
}

/// Find the virtual memory area that contains the given virtual address.
///
/// Returns null if no area contains the address.
pub fn findVirtualArea(vaddr: Virt) ?*VmArea {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    return if (area_list.find(vaddr)) |node| node.container() else null;
}

/// Allocate virtually contiguous, physically non-contiguous memory of the given size.
///
/// Each page is backed by an independently allocated physical page.
pub fn valloc(size: usize) Error![]u8 {
    const aligned_size = std.mem.alignForward(usize, size, mem.page_size);

    const area = try allocateVirtualArea(aligned_size);
    errdefer releaseArea(area);

    const pt = mem.getKernelPageTable();
    for (0..aligned_size / mem.page_size) |i| {
        const vaddr = area.start + i * mem.page_size;
        const page = try mem.page.allocPagesP(1);
        const paddr: Phys = @intFromPtr(page.ptr);
        errdefer mem.page.freePagesP(page);

        try arch.mmu.map4kb(pt, .{
            .va = vaddr,
            .pa = paddr,
            .size = mem.page_size,
            .perm = .kernel_rw,
            .attr = .normal,
        }, .{}, mem.page);
        errdefer arch.mmu.unmap4kb(
            pt,
            vaddr,
            mem.page_size,
            mem.page,
        ) catch {};

        const vms = try mem.bin.create(VmStruct);
        vms.* = .{
            .virt = vaddr,
            .phys = paddr,
            .size = mem.page_size,
            .area = area,
            .rbnode = .init,
        };
        area.vmtree.insert(vms);
    }

    area._status = .mapped;
    return @as([*]u8, @ptrFromInt(area.start))[0..size];
}

/// Free memory allocated by `valloc()`.
///
/// The caller must pass the exact slice returned by `valloc()`.
pub fn vfree(memory: []u8) void {
    const vaddr = @intFromPtr(memory.ptr);
    const area = findVirtualArea(vaddr) orelse
        @panic("vfree: tried to free unallocated memory");

    rtt.expectEqual(area.start, vaddr);

    releaseArea(area);
}

/// Delete the given virtual memory area from the used list and connect it to the free list.
fn freeArea(area: *VmArea) void {
    rtt.expect(lock.isLocked());

    area_list.delete(area);
    area._status = .not_mapped;
    area.rbnode = .init;
    free_list.insert(area);
}

/// Unmap and free all physical pages in the area, then return it to the free list.
fn releaseArea(area: *VmArea) void {
    const pt = mem.getKernelPageTable();
    var it = area.vmtree.iterator();
    while (it.next()) |node| {
        const vms = node.container();
        arch.mmu.unmap4kb(
            pt,
            vms.virt,
            vms.size,
            mem.page,
        ) catch {};
        mem.page.freePagesP(@as([*]u8, @ptrFromInt(vms.phys))[0..vms.size]);
        area.vmtree.delete(vms);
        mem.bin.destroy(vms);
    }

    freeVirtualArea(area);
}

// =============================================================
// Internals
// =============================================================

/// Single virtual-physical memory mapping descriptor.
///
/// The descriptor represents a relationship between a virtual address range and a physical address range.
/// The descriptor is a single node in the `VmArea`.
const VmStruct = struct {
    /// Virtual address of this mapping.
    virt: Virt,
    /// Physical address of the backing page.
    phys: Phys,
    /// Size in bytes of this mapping.
    size: usize,
    /// VmArea this mapping belongs to.
    area: *VmArea,
    /// List node.
    rbnode: Tree.Node,

    /// Rb tree of VmStruct.
    const Tree = RbTree(
        VmStruct,
        "rbnode",
        compareVmStruct,
        compareVmStructByKey,
    );

    /// Compares two `VmStruct` instances based on their virtual addresses.
    ///
    /// BUG: Zig v0.14.1: using `*const VmStruct` as an argument leads to a dependency loop error.
    ///     See https://github.com/ziglang/zig/issues/12325.
    fn compareVmStruct(ap: *const anyopaque, bp: *const anyopaque) std.math.Order {
        const a: *const VmStruct = @ptrCast(@alignCast(ap));
        const b: *const VmStruct = @ptrCast(@alignCast(bp));
        if (a.virt < b.virt) return .lt;
        if (a.virt > b.virt) return .gt;
        return .eq;
    }

    /// Compares a `VmStruct` with a key based on the virtual address.
    ///
    /// BUG: Same as above. See https://github.com/ziglang/zig/issues/12325.
    fn compareVmStructByKey(key: Virt, ap: *const anyopaque) std.math.Order {
        const a: *const VmStruct = @ptrCast(@alignCast(ap));
        if (key < a.virt) return .lt;
        if (key >= a.virt + a.size) return .gt;
        return .eq;
    }
};

/// Virtually contiguous area.
const VmArea = struct {
    /// Start address of this area.
    start: usize,
    /// End virtual address of this area.
    end: usize,
    /// List node.
    rbnode: Tree.Node = .init,
    /// VmStruct list for this area.
    vmtree: VmStruct.Tree,
    /// Status of the area.
    _status: Status = .not_mapped,

    /// RB tree of VmArea.
    const Tree = RbTree(
        @This(),
        "rbnode",
        compareVmArea,
        compareVmAreaByKey,
    );

    const Status = enum {
        /// Backing physical pages are not mapped.
        not_mapped,
        /// Mapped to physical pages.
        mapped,
    };

    /// Compares two `VmArea` instances based on their start addresses.
    ///
    /// BUG: Zig v0.14.1: using `*const VmArea` as an argument leads to a dependency loop error.
    ///     See https://github.com/ziglang/zig/issues/12325.
    fn compareVmArea(ap: *const anyopaque, bp: *const anyopaque) std.math.Order {
        const a: *const VmArea = @ptrCast(@alignCast(ap));
        const b: *const VmArea = @ptrCast(@alignCast(bp));
        if (a.start < b.start) return .lt;
        if (a.start > b.start) return .gt;
        return .eq;
    }

    /// Compares a `VmArea` with a key based on the start address of the `VmArea`.
    ///
    /// BUG: Same as above. See https://github.com/ziglang/zig/issues/12325.
    fn compareVmAreaByKey(key: Virt, ap: *const anyopaque) std.math.Order {
        const a: *const VmArea = @ptrCast(@alignCast(ap));
        if (key < a.start) return .lt;
        if (key >= a.end) return .gt;
        return .eq;
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.va);
const Allocator = std.mem.Allocator;
const urd = @import("urthr");
const mem = urd.mem;
const Virt = mem.Virt;
const Phys = mem.Phys;
const SpinLock = urd.sync.SpinLock;
const common = @import("common");
const rtt = common.rtt;
const util = common.util;
const RbTree = common.RbTree;
const arch = @import("arch").impl;
const vmap = @import("vmemmap.zig");
