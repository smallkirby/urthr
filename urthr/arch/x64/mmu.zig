pub const Error = error{
    /// Current mapping does not match the requested mapping.
    InvalidMapping,
} || PageAllocator.Error;

pub const MapArgument = struct {
    /// Virtual address to map.
    va: usize,
    /// Physical address to map.
    pa: usize,
    /// Size in bytes to map.
    size: usize,
    /// Permission of the mapping.
    perm: Permission,
    /// Attribute of the mapping.
    attr: Attribute,
};

pub const MapOptions = struct {
    /// Returns an error if the given addresses are not aligned to the given granule size.
    exact: bool = true,
};

/// Describes a pair of page tables.
pub const PageTablePair = struct {
    /// Virtual address of the page table for lower VA range.
    l0: ?PageTable = null,
    /// Virtual address of the page table for higher VA range.
    l1: ?PageTable = null,

    /// Select the page table for the given virtual address.
    pub fn select(_: PageTablePair, _: usize) PageTable {
        @panic("unimplemented");
    }
};

/// Describes a single root page table.
pub const PageTable = struct {
    _tbl: usize,

    pub fn phys(_: PageTable, _: PageAllocator) usize {
        @panic("unimplemented");
    }
};

/// Allocate a new root page table.
pub fn createPageTable(_: PageAllocator) Error!PageTable {
    @panic("unimplemented");
}

/// Allocate a new pair of root page tables.
pub fn createPageTablePair(_: PageAllocator) Error!PageTablePair {
    @panic("unimplemented");
}

/// Maps the VA to PA using 4KiB pages.
pub fn map4kb(_: PageTablePair, _: MapArgument, _: MapOptions, _: PageAllocator) Error!void {
    @panic("unimplemented");
}

/// Maps the VA to PA using 2MiB pages.
pub fn map2mb(_: PageTablePair, _: MapArgument, _: MapOptions, _: PageAllocator) Error!void {
    @panic("unimplemented");
}

/// Maps the VA to PA using 1GiB pages.
pub fn map1gb(_: PageTablePair, _: MapArgument, _: MapOptions, _: PageAllocator) Error!void {
    @panic("unimplemented");
}

/// Changes permissions of an existing VA range using 4KiB pages.
pub fn remap4kb(_: PageTablePair, _: usize, _: usize, _: Permission, _: PageAllocator) Error!void {
    @panic("unimplemented");
}

/// Unmaps the VA range using 4KiB pages.
pub fn unmap4kb(_: PageTablePair, _: usize, _: usize, _: PageAllocator) Error!void {
    @panic("unimplemented");
}

/// Unmaps the VA range using 2MiB pages.
pub fn unmap2mb(_: PageTablePair, _: usize, _: usize, _: PageAllocator) Error!void {
    @panic("unimplemented");
}

/// Unmaps the VA range using 1GiB pages.
pub fn unmap1gb(_: PageTablePair, _: usize, _: usize, _: PageAllocator) Error!void {
    @panic("unimplemented");
}

/// Enable MMU.
pub fn enable(_: PageTablePair, _: PageAllocator) void {
    @panic("unimplemented");
}

/// Switch the user-space page table (TTBR0_EL1) to the given page table.
///
/// If `l0` is null, TTBR0_EL1 is cleared.
/// TLB is flushed after the switch.
pub fn switchUserTable(_: ?PageTable, _: PageAllocator) void {
    @panic("unimplemented");
}

/// Translate the given virtual address to physical address by walking the page tables.
pub fn translateWalk(_: PageTable, _: usize, _: PageAllocator) ?usize {
    @panic("unimplemented");
}

/// Get the physical address corresponding to the given virtual address.
pub fn getPhysicalAddress(_: usize) usize {
    @panic("unimplemented");
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const rtt = common.rtt;
const units = common.units;
const util = common.util;
const Attribute = common.mem.Attribute;
const Permission = common.mem.Permission;
const PageAllocator = common.mem.PageAllocator;
