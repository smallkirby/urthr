//! Manages virtual memory allocation.

pub const Error = mem.Error;

/// Spin lock on virtual address management.
var lock = SpinLock{};
/// All allocated virtual memory areas.
var area_list: VmArea.Tree = .{};

/// Start of the virtual address space managed by this allocator.
const vbase = vmap.vmem.start;
/// End of the virtual address space managed by this allocator.
const vend = vmap.vmem.end;

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
    rbnode: Tree.Node,
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

/// Allocate a virtual memory area with the given size.
pub fn allocate(size: usize) Error!*VmArea {
    rtt.expectEqual(0, size % common.mem.size_4kib);

    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    // Calculate the start address to assign.
    const start = if (area_list.max()) |max| max.container().end else vbase;
    const end = start + size;
    if (end >= vend) {
        return Error.OutOfVirtualMemory;
    }

    // Construct the virtual area node.
    const area = try gallocator().create(VmArea);
    area.* = .{
        .start = start,
        .end = end,
        .rbnode = .init,
        .vmtree = .{},
    };
    area_list.insert(area);

    return area;
}

const gallocator = urd.mem.getGeneralAllocator;
const pallocator = urd.mem.getPageAllocator;

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
const SpinLock = urd.SpinLock;
const common = @import("common");
const rtt = common.rtt;
const util = common.util;
const RbTree = common.RbTree;
const arch = @import("arch").impl;
const vmap = @import("vmemmap.zig");
