//! Sv48 MMU.

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
    /// Whether to flush the TLB after the operation completes.
    flush: bool = true,
};

pub const RemapOptions = struct {
    /// Whether to flush the TLB after the operation completes.
    flush: bool = true,
};

pub const UnmapOptions = struct {
    /// Whether to flush the TLB after the operation completes.
    flush: bool = true,
};

const todo = "TODO: MMU is not supported on riscv64 yet.";

/// Describes a virtual address space.
pub const AddressSpace = struct {
    /// Root page table.
    _root: ?PageTable = null,

    /// Returns whether this address space has no user table.
    pub fn isKernelOnly(self: AddressSpace) bool {
        return self._root == null;
    }

    /// Returns a copy of this address space with the user mapping dropped.
    pub fn kernelOnly(self: AddressSpace) AddressSpace {
        _ = self;
        @panic(todo);
    }

    /// Returns a copy of this address space with the user mapping dropped.
    pub fn installUserTable(self: AddressSpace, user: PageTable) AddressSpace {
        _ = self;
        _ = user;
        @panic(todo);
    }
};

/// Describes a single root page table.
pub const PageTable = struct {
    _tbl: []u64,
};

/// Allocate a new root page table.
pub fn createPageTable(_: PageAllocator) Error!PageTable {
    @panic(todo);
}

/// Frees the user page tables of the given address space.
pub fn destroyAddressSpace(_: AddressSpace, _: PageAllocator) void {
    @panic(todo);
}

/// Allocate a new address space.
pub fn createAddressSpace(_: PageAllocator) Error!AddressSpace {
    @panic(todo);
}

/// Fix up the table addresses held by the address space.
pub fn relocate(_: *AddressSpace, _: PageAllocator) void {
    @panic(todo);
}

/// Maps the VA to PA using 4KiB pages.
pub fn map4kb(_: AddressSpace, _: MapArgument, _: MapOptions, _: PageAllocator) Error!void {
    @panic(todo);
}

/// Maps the VA to PA using 2MiB pages.
pub fn map2mb(_: AddressSpace, _: MapArgument, _: MapOptions, _: PageAllocator) Error!void {
    @panic(todo);
}

/// Maps the VA to PA using 1GiB pages.
pub fn map1gb(_: AddressSpace, _: MapArgument, _: MapOptions, _: PageAllocator) Error!void {
    @panic(todo);
}

/// Changes permissions of an existing VA range using 4KiB pages.
pub fn remap4kb(_: AddressSpace, _: usize, _: usize, _: Permission, _: RemapOptions, _: PageAllocator) Error!void {
    @panic(todo);
}

/// Unmaps the VA range using 4KiB pages.
pub fn unmap4kb(_: AddressSpace, _: usize, _: usize, _: UnmapOptions, _: PageAllocator) Error!void {
    @panic(todo);
}

/// Unmaps the VA range using 2MiB pages.
pub fn unmap2mb(_: AddressSpace, _: usize, _: usize, _: UnmapOptions, _: PageAllocator) Error!void {
    @panic(todo);
}

/// Unmaps the VA range using 1GiB pages.
pub fn unmap1gb(_: AddressSpace, _: usize, _: usize, _: UnmapOptions, _: PageAllocator) Error!void {
    @panic(todo);
}

/// Enable MMU.
pub fn enable(_: AddressSpace, _: PageAllocator) void {
    @panic(todo);
}

/// Switch the current address space.
pub fn switchAddressSpace(_: AddressSpace, _: PageAllocator) void {
    @panic(todo);
}

/// Translate the given virtual address to physical address by walking the page tables.
pub fn translateWalk(_: AddressSpace, _: usize, _: PageAllocator) ?usize {
    @panic(todo);
}

/// Get the physical address corresponding to the given virtual address.
pub fn getPhysicalAddress(_: usize) usize {
    @panic(todo);
}

/// TLB maintenance.
pub const tlb = struct {
    /// Whether IPI is needed for cross-CPU TLB shootdown.
    pub const supports_global = true;

    pub const Scope = enum {
        /// Local to this core.
        local,
        /// All CPUs.
        global,
    };

    /// Invalidate all TLB entries.
    pub fn invalidateAll(_: AddressSpace, _: Scope) void {
        @panic(todo);
    }

    /// Invalidate the TLB entries covering the given virtual address range.
    pub fn invalidateRange(_: AddressSpace, _: usize, _: usize, _: Scope) void {
        @panic(todo);
    }
};

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const PageAllocator = common.mem.PageAllocator;
const Attribute = common.mem.Attribute;
const Permission = common.mem.Permission;
