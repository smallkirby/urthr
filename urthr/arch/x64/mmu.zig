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

/// Describes a virtual address space.
///
/// Internal fields are arch-specific and must not be accessed outside this file.
pub const AddressSpace = struct {
    _l0: ?PageTable = null,
    _l1: ?PageTable = null,

    /// Select the page table for the given virtual address.
    pub fn select(_: AddressSpace, _: usize) PageTable {
        @panic("unimplemented");
    }

    /// Returns whether this address space has no user (lower VA range) table.
    pub fn isKernelOnly(self: AddressSpace) bool {
        return self._l0 == null;
    }

    /// Returns a copy of this address space with the user table dropped.
    pub fn kernelOnly(self: AddressSpace) AddressSpace {
        return .{ ._l1 = self._l1 };
    }

    /// Returns a copy of this address space with the user table replaced.
    pub fn withUserTable(self: AddressSpace, user: PageTable) AddressSpace {
        return .{ ._l0 = user, ._l1 = self._l1 };
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

/// Allocate a new address space with fresh kernel and user root tables.
pub fn createAddressSpace(_: PageAllocator) Error!AddressSpace {
    @panic("unimplemented");
}

/// Fix up the table addresses held by the address space.
///
/// This function is intended to be called after identity-mapping is unmapped
/// to fix up the virtual address of the page tables.
pub fn relocate(_: *AddressSpace, _: PageAllocator) void {
    @panic("unimplemented");
}

/// Maps the VA to PA using 4KiB pages.
pub fn map4kb(_: AddressSpace, _: MapArgument, _: MapOptions, _: PageAllocator) Error!void {
    @panic("unimplemented");
}

/// Maps the VA to PA using 2MiB pages.
pub fn map2mb(_: AddressSpace, _: MapArgument, _: MapOptions, _: PageAllocator) Error!void {
    @panic("unimplemented");
}

/// Maps the VA to PA using 1GiB pages.
pub fn map1gb(_: AddressSpace, _: MapArgument, _: MapOptions, _: PageAllocator) Error!void {
    @panic("unimplemented");
}

/// Changes permissions of an existing VA range using 4KiB pages.
pub fn remap4kb(_: AddressSpace, _: usize, _: usize, _: Permission, _: PageAllocator) Error!void {
    @panic("unimplemented");
}

/// Unmaps the VA range using 4KiB pages.
pub fn unmap4kb(_: AddressSpace, _: usize, _: usize, _: PageAllocator) Error!void {
    @panic("unimplemented");
}

/// Unmaps the VA range using 2MiB pages.
pub fn unmap2mb(_: AddressSpace, _: usize, _: usize, _: PageAllocator) Error!void {
    @panic("unimplemented");
}

/// Unmaps the VA range using 1GiB pages.
pub fn unmap1gb(_: AddressSpace, _: usize, _: usize, _: PageAllocator) Error!void {
    @panic("unimplemented");
}

/// Enable MMU.
pub fn enable(_: AddressSpace, _: PageAllocator) void {
    @panic("unimplemented");
}

/// Switch the user-space address space to the user address space of `pt`.
///
/// If `pt` has no user table, the user table is cleared.
/// TLB is flushed after the switch.
pub fn switchAddressSpace(_: AddressSpace, _: PageAllocator) void {
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
