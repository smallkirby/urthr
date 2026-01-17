//! Manages allocation of physical memory not backed by DRAM.

const Error = mem.Error;

const Self = @This();

/// Spin lock.
_lock: urd.SpinLock = .{},
/// List of memory resources.
///
/// This list must be sorted by the start address of the memory resources.
_resources: ResourceList = .{},

/// Vtable for IoAllocator interface.
const vtable = IoAllocator.Vtable{
    .ioremap = ioremap,
    .reserve = reserve,
};

/// Initialize a VmAllocator instance.
pub fn init(self: *Self) void {
    self.* = .{
        ._lock = .{},
    };
}

/// Get the IoAllocator interface.
pub fn interface(self: *Self) IoAllocator {
    return IoAllocator{
        .ptr = self,
        .vtable = &vtable,
    };
}

// =============================================================
// Interface Implementation
// =============================================================

/// Map the given physical I/O memory region into the virtual address space.
///
/// Caller must ensure that the given physical address range is reserved before calling this function.
fn ioremap(ctx: *anyopaque, phys: usize, size: usize) IoAllocator.Error!usize {
    rtt.expect(util.isAligned(size, common.mem.size_4kib));
    rtt.expect(util.isAligned(phys, common.mem.size_4kib));

    const self: *Self = @ptrCast(@alignCast(ctx));
    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);

    // Allocate a virtual memory area.
    const vm_area = try mem.vallocator.allocate(size);

    // Map the physical address to the allocated virtual memory range,
    // using as large pages as possible.
    var remaining = size;
    while (remaining > 0) {
        const v = vm_area.start + (size - remaining);
        const p = phys + (size - remaining);

        remaining -= try mapPage(v, p, remaining);
    }

    // TODO: fill VmStruct

    return vm_area.start;
}

/// Reserve a physical memory range as a resource.
///
/// If `parent` is given, the new resource is created as a child of the parent resource.
fn reserve(ctx: *anyopaque, name: []const u8, start: usize, size: usize, parent: ?*Resource) Error!*Resource {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const end = start + size;

    if (!util.isAligned(start, common.mem.size_4kib)) {
        return Error.InvalidArgument;
    }
    if (!util.isAligned(size, common.mem.size_4kib)) {
        return Error.InvalidArgument;
    }

    const resource = if (parent) |p| blk: {
        // Check for overlapping with existing children.
        var current = p.children.first;
        while (current) |res| : (current = res.list_head.next) {
            if (res.phys < end and start < res.phys + res.size) {
                return Error.NotAvailable;
            }
        }

        // Create the child resource.
        const child = try gallocator().create(Resource);
        child.* = .{
            .name = name,
            .phys = start,
            .size = size,
            .parent = p,
            .children = .{},
        };
        p.children.insertSorted(child, compareResources);

        break :blk child;
    } else blk: {
        // Check for overlapping with existing resources.
        var current = self._resources.first;
        while (current) |res| : (current = res.list_head.next) {
            if (res.phys < end and start < res.phys + res.size) {
                return Error.NotAvailable;
            }
        }

        // Create the resource.
        const resource = try gallocator().create(Resource);
        resource.* = .{
            .name = name,
            .phys = start,
            .size = size,
        };
        self._resources.insertSorted(resource, compareResources);

        break :blk resource;
    };

    self.rttResourcesSorted();

    return resource;
}

// =============================================================
// Utilities
// =============================================================

/// Comparator function for `Resource`.
fn compareResources(a: *Resource, b: *Resource) std.math.Order {
    if (a.phys < b.phys) return .lt;
    if (a.phys > b.phys) return .gt;
    return .eq;
}

/// Map a given virtual address to a physical address.
///
/// Returns the size of mapped range in bytes.
fn mapPage(virt: Virt, phys: Phys, max: usize) Error!usize {
    // Map using 1GiB pages if possible.
    if (isMappableAs(virt, phys, max, common.mem.size_1gib)) {
        const map_size = util.rounddown(max, common.mem.size_1gib);
        try arch.mmu.map1gb(
            phys,
            virt,
            map_size,
            .kernel_rw,
            .device,
            mem.getPageAllocator(),
        );
        return map_size;
    }

    // Map using 2MiB pages, until next 1GiB boundary.
    if (isMappableAs(virt, phys, max, common.mem.size_2mib)) {
        const map_size = @min(
            util.rounddown(max, common.mem.size_2mib),
            common.mem.size_1gib - (virt % common.mem.size_1gib),
        );
        try arch.mmu.map2mb(
            phys,
            virt,
            map_size,
            .kernel_rw,
            .device,
            mem.getPageAllocator(),
        );
        return map_size;
    }

    // Map using 4KiB pages, until next 2MiB boundary.
    {
        const map_size = @min(
            max,
            common.mem.size_2mib - (virt % common.mem.size_2mib),
        );
        try arch.mmu.map4kb(
            phys,
            virt,
            map_size,
            .kernel_rw,
            .device,
            mem.getPageAllocator(),
        );
        return map_size;
    }
}

/// Check if the given memory range can be mapped using the given page size.
fn isMappableAs(virt: Virt, phys: Phys, size: usize, page_size: usize) bool {
    return util.isAligned(virt, page_size) and
        util.isAligned(phys, page_size) and
        size >= page_size;
}

/// Get a general-purpose allocator.
fn gallocator() Allocator {
    return urd.mem.getGeneralAllocator();
}

/// Get a page allocator.
fn pallocator() PageAllocator {
    return urd.mem.getPageAllocator();
}

// =============================================================
// Debug
// =============================================================

/// Print all resources to the given logger for debug.
pub fn debugPrintResources(self: *const Self, logger: anytype) void {
    var current = self._resources.first;
    while (current) |res| : (current = res.list_head.next) {
        logger("{X:0>12}-{X:0>12}    : {s}", .{
            res.phys,
            res.phys + res.size,
            res.name,
        });

        var child_current = res.children.first;
        while (child_current) |child| : (child_current = child.list_head.next) {
            logger("   {X:0>12}-{X:0>12} :  {s}", .{
                child.phys,
                child.phys + child.size,
                child.name,
            });
        }
    }
}

// =============================================================
// Tests
// =============================================================

fn rttResourcesSorted(self: *Self) void {
    if (!urd.enable_rtt) return;

    const S = struct {
        fn f(list: ResourceList) void {
            rtt.expect(list.isSorted(compareResources));

            var current = list.first;
            while (current) |res| : (current = res.list_head.next) {
                f(res.children);
            }
        }
    };

    S.f(self._resources);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.VmAllocator);
const Allocator = std.mem.Allocator;

const urd = @import("urthr");
const mem = urd.mem;
const Virt = mem.Virt;
const Phys = mem.Phys;
const common = @import("common");
const IoAllocator = common.IoAllocator;
const Resource = IoAllocator.Resource;
const ResourceList = IoAllocator.ResourceList;
const PageAllocator = common.PageAllocator;
const rtt = common.rtt;
const units = common.units;
const util = common.util;
const RbTree = common.RbTree;
const arch = @import("arch").impl;
