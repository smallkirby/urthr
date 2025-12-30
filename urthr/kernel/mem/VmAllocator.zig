//! Manages allocation of virtual address space.
//!
//! The region is backed by non-contiguous physical pages.
//! The region is usually not mapped to physical pages until requested.
//!
//! This allocator uses 4KiB pages only.
//! You can change the permission of allocated pages as needed.

const Error = mem.Error;

const Self = @This();
const VmAllocator = Self;

/// Spin lock.
_lock: urd.SpinLock = .{},
/// All areas allocated in the valloc region.
_area_list: VmArea.Tree = .{},

/// Start virtual address of the region managed by this allocator.
_vstart: Virt,
/// End virtual address of the region managed by this allocator.
_vend: Virt,

/// Vtable for IoAllocator interface.
const vtable = IoAllocator.Vtable{
    .ioremap = ioremap,
    .reserve = reserve,
};

/// Single virtually contiguous area.
const VmArea = struct {
    /// Start virtual address of this area.
    start: Virt,
    /// End virtual address of this area.
    end: Virt,
    /// Position of the guard page.
    guard_position: GuardPagePosition,
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

    /// Allocate a new virtual memory area.
    ///
    /// Newly allocated areas are inserted into the RB tree.
    /// They're not mapped to physical pages yet.
    pub fn allocateVrange(
        vmallocator: *VmAllocator,
        size: usize,
        align_size: usize,
        guard: GuardPagePosition,
    ) Error!*VmArea {
        urd.rtt.expectEqual(0, size % mem.size_4kib);

        const size_aligned = util.roundup(size, align_size);
        const start = if (vmallocator._area_list.max()) |max| max.container().end else vmallocator._vstart;
        const start_aligned = util.roundup(start, align_size);
        const end = start_aligned + size_aligned + switch (guard) {
            .before, .after => @as(usize, mem.size_4kib),
            .none => @as(usize, 0),
        };
        if (end >= vmallocator._vend) {
            return error.OutOfVirtualMemory;
        }

        const area = try gallocator().create(VmArea);
        area.* = .{
            .start = start_aligned,
            .end = end,
            .guard_position = guard,
            .rbnode = .init,
            .vmtree = .{},
        };
        vmallocator._area_list.insert(area);

        return area;
    }

    /// Free the given virtual memory area.
    pub fn freeVrange(self: *VmAllocator, area: *VmArea) void {
        urd.rtt.expect(self._area_list.contains(area.start));

        self._area_list.delete(area);
        gallocator().destroy(area);
    }

    /// Allocate physical pages and map them to the given virtual memory area.
    ///
    /// - self: The virtual memory range to map.
    ///     When the guard page is .before, a first page is not mapped.
    ///     When the guard page is .after, a last page is not mapped.
    pub fn allocateMapPhysicalPages(self: *VmArea) Error!void {
        urd.rtt.expectEqual(.not_mapped, self._status);

        const num_pages = (self.end - self.start) / mem.size_4kib - switch (self.guard_position) {
            .before, .after => @as(usize, 1),
            .none => @as(usize, 0),
        };
        const vstart: Virt = self.start + mem.size_4kib * switch (self.guard_position) {
            .before => @as(usize, 1),
            .after => @as(usize, 0),
            .none => @as(usize, 0),
        };

        var vmtree = VmStruct.Tree{};
        errdefer {
            var vmtree_iter = vmtree.iterator();
            while (vmtree_iter.next()) |node| {
                urd.unimplemented("unmap");
                gallocator().destroy(node);
            }
        }

        var i: usize = 0;
        while (i < num_pages) : (i += 1) {
            const page = try pallocator().allocPages(1);
            errdefer pallocator().freePagesV(page);

            const virt = vstart + i * mem.size_4kib;
            const phys = pallocator().translateP(page);

            arch.mmu.map4kb(
                virt,
                phys,
                1,
                .read_write,
            ) catch return Error.OutOfVirtualMemory;

            const vmstruct = try gallocator().create(VmStruct);
            errdefer gallocator().destroy(vmstruct);
            vmstruct.* = .{
                .virt = virt,
                .phys = phys,
                .size = mem.size_4kib,
                .area = self,
                .rbnode = .{},
            };
            vmtree.insert(vmstruct);
        }

        self.vmtree = vmtree;
        self._status = .mapped;
    }

    /// Unmap the physical pages backing the given virtual memory area, then free the internal structures.
    pub fn freeUnmapPhysicalPages(self: *VmArea) !void {
        var vmtree_iter = self.vmtree.iterator();
        while (vmtree_iter.next()) |node| {
            const vmstruct = node.container();
            urd.unimplemented("unmap");
            gallocator().destroy(vmstruct);
        }
    }

    /// Get the memory slice for the virtual memory area.
    ///
    /// Guard page is omitted.
    /// If the size is larger than the area, the returned slice is smaller than the requested size.
    pub fn usableSlice(self: *const VmArea, size: usize) []u8 {
        const ptr: [*]u8 = @ptrFromInt(self.start);
        const offset = switch (self.guard_position) {
            .before => @as(usize, mem.size_4kib),
            .after => @as(usize, 0),
            .none => @as(usize, 0),
        };
        const max_size = switch (self.guard_position) {
            .before, .after => self.end - self.start - mem.size_4kib,
            .none => self.end - self.start,
        };

        return (ptr + offset)[0..@min(size, max_size)];
    }
};

/// Single virtual-physical memory mapping descriptor.
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

/// Where to place the guard page.
const GuardPagePosition = enum {
    /// Before the requested region.
    before,
    /// After the requested region.
    after,
    /// No guard page.
    none,
};

/// Initialize a VmAllocator instance.
pub fn init(self: *Self, comptime vstart: Virt, comptime vend: Virt) void {
    self.* = .{
        ._lock = .{},
        ._area_list = .{},
        ._vstart = vstart,
        ._vend = vend,
    };
}

/// Allocates a memory from vmap region.
///
/// The allocated memory is virtually contiguous, but can be backed by non-contiguous physical pages.
pub fn virtualAlloc(self: *VmAllocator, size: usize, guard: GuardPagePosition) Error![]u8 {
    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);

    // Allocate a virtual memory range.
    const vmarea = try VmArea.allocateVrange(
        self,
        size,
        mem.size_4kib,
        guard,
    );
    errdefer VmArea.freeVrange(self, vmarea);

    // Allocate backing physical pages and map them to the allocated virtual memory area.
    try vmarea.allocateMapPhysicalPages();

    // Returns the slice with the exact requested size.
    return vmarea.usableSlice(size);
}

/// Frees a memory allocated by `virtualAlloc()`.
pub fn virtualFree(self: *VmAllocator, ptr: []u8) void {
    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);

    const vmarea_node = self._area_list.find(@intFromPtr(ptr.ptr)) orelse {
        @panic("Invalid pointer passed to VmAllocator.virtualFree()");
    };
    const vmarea = vmarea_node.container();

    vmarea.freeUnmapPhysicalPages() catch |err| {
        log.err("Failed to unmap physical pages for virtual memory area: {s}", .{@errorName(err)});
    };
    VmArea.freeVrange(self, vmarea);
}

/// Map the given physical I/O memory region into the virtual address space.
fn ioremap(ctx: *anyopaque, paddr: usize, size: usize) IoAllocator.Error!usize {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);

    rtt.expectEqual(0, size % mem.size_4kib);
    rtt.expectEqual(0, paddr % mem.size_4kib);
    const num_pages = size / mem.size_4kib;

    // Allocate a virtual memory range.
    const vmarea_node = try VmArea.allocateVrange(
        self,
        size,
        mem.size_4kib,
        .none,
    );
    errdefer VmArea.freeVrange(self, vmarea_node);

    // Map the physical address to the allocated virtual memory range.
    var vmtree = VmStruct.Tree{};
    errdefer {
        var vmtree_iter = vmtree.iterator();
        while (vmtree_iter.next()) |node| {
            urd.unimplemented("unmap");
            gallocator().destroy(node);
        }
    }

    var i: usize = 0;
    while (i < num_pages) : (i += 1) {
        const virt = vmarea_node.start + i * mem.size_4kib;
        const phys = paddr + i * mem.size_4kib;

        arch.mmu.map4kb(
            phys,
            virt,
            mem.size_4kib,
            .kernel_rw,
            .device,
            pallocator(),
        ) catch return Error.OutOfVirtualMemory;

        const vmstruct = try gallocator().create(VmStruct);
        errdefer gallocator().destroy(vmstruct);
        vmstruct.* = .{
            .virt = virt,
            .phys = phys,
            .size = mem.size_4kib,
            .area = vmarea_node,
            .rbnode = .{},
        };
        vmtree.insert(vmstruct);
    }

    vmarea_node.vmtree = vmtree;
    vmarea_node._status = .mapped;

    return vmarea_node.start;
}

fn reserve(_: *anyopaque, name: []const u8, paddr: usize, size: usize) IoAllocator.Error!void {
    _ = try resource.requestResource(
        name,
        paddr,
        size,
        gallocator(),
    );
}

/// Get the IoAllocator interface.
pub fn interface(self: *Self) IoAllocator {
    return IoAllocator{
        .ptr = self,
        .vtable = &vtable,
    };
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
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.VmAllocator);
const Allocator = std.mem.Allocator;

const urd = @import("urthr");
const mem = urd.mem;
const rtt = urd.rtt;
const Virt = mem.Virt;
const Phys = mem.Phys;
const common = @import("common");
const IoAllocator = common.IoAllocator;
const PageAllocator = common.PageAllocator;
const util = common.util;
const RbTree = common.RbTree;
const arch = @import("arch").impl;
const resource = @import("resource.zig");
