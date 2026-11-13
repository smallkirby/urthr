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
    /// Root page table shared by both VA halves.
    _root: ?PageTable = null,
    /// Whether the lower VA half of the root table currently holds a user mapping.
    _has_user: bool = false,

    /// Select the page table for the given virtual address.
    pub fn select(self: AddressSpace, va: usize) PageTable {
        rtt.expect(isCanonical(va));
        return self._root orelse @panic("table not present");
    }

    /// Returns whether this address space has no user table.
    pub fn isKernelOnly(self: AddressSpace) bool {
        return !self._has_user;
    }

    /// Returns a copy of this address space with the user mapping dropped.
    pub fn kernelOnly(self: AddressSpace) AddressSpace {
        return .{ ._root = self._root, ._has_user = false };
    }

    /// Returns a copy of this address space installed with the given user table.
    pub fn installUserTable(self: AddressSpace, user: PageTable) AddressSpace {
        rtt.expect(!self._has_user);
        const ktbl = self._root orelse @panic("kernel table not present");
        @memcpy(user._tbl[root_half_ents..], ktbl._tbl[root_half_ents..]);
        return .{ ._root = user, ._has_user = true };
    }
};

/// Describes a single root page table.
pub const PageTable = struct {
    _tbl: []TableEntry,

    /// Get the physical address of this page table.
    pub fn phys(self: PageTable, allocator: PageAllocator) usize {
        return @intFromPtr(allocator.translateP(self._tbl).ptr);
    }
};

/// Allocate a new root page table.
pub fn createPageTable(allocator: PageAllocator) Error!PageTable {
    return .{ ._tbl = try allocNewTable(allocator) };
}

/// Create a new address space with a fresh root table.
pub fn createAddressSpace(allocator: PageAllocator) Error!AddressSpace {
    return .{ ._root = try createPageTable(allocator) };
}

/// Frees the user page tables of the given address space.
pub fn destroyAddressSpace(_: AddressSpace, _: PageAllocator) void {
    @panic(todo);
}

/// Fix up the table addresses held by the address space.
///
/// This function is intended to be called after identity-mapping is unmapped
/// to fix up the virtual address of the page tables.
pub fn relocate(as: *AddressSpace, allocator: PageAllocator) void {
    if (as._root) |*t| {
        t._tbl = allocator.translateV(t._tbl);
    }
}

/// Maps the VA to PA using 4KiB pages.
pub fn map4kb(as: AddressSpace, arg: MapArgument, opts: MapOptions, allocator: PageAllocator) Error!void {
    return mapImpl(as.select(arg.va), arg, .@"4kb", opts, allocator);
}

/// Maps the VA to PA using 2MiB pages.
pub fn map2mb(as: AddressSpace, arg: MapArgument, opts: MapOptions, allocator: PageAllocator) Error!void {
    return mapImpl(as.select(arg.va), arg, .@"2mb", opts, allocator);
}

/// Maps the VA to PA using 1GiB pages.
pub fn map1gb(as: AddressSpace, arg: MapArgument, opts: MapOptions, allocator: PageAllocator) Error!void {
    return mapImpl(as.select(arg.va), arg, .@"1gb", opts, allocator);
}

/// Changes permissions of an existing VA range using 4KiB pages.
pub fn remap4kb(as: AddressSpace, va: usize, size: usize, perm: Permission, opts: RemapOptions, allocator: PageAllocator) Error!void {
    return remapImpl(as.select(va), va, size, .@"4kb", perm, opts, allocator);
}

/// Changes permissions of an existing VA range using 2MiB pages.
pub fn remap2mb(as: AddressSpace, va: usize, size: usize, perm: Permission, opts: RemapOptions, allocator: PageAllocator) Error!void {
    return remapImpl(as.select(va), va, size, .@"2mb", perm, opts, allocator);
}

/// Changes permissions of an existing VA range using 1GiB pages.
pub fn remap1gb(as: AddressSpace, va: usize, size: usize, perm: Permission, opts: RemapOptions, allocator: PageAllocator) Error!void {
    return remapImpl(as.select(va), va, size, .@"1gb", perm, opts, allocator);
}

/// Unmaps the VA range using 4KiB pages.
pub fn unmap4kb(as: AddressSpace, va: usize, size: usize, opts: UnmapOptions, allocator: PageAllocator) Error!void {
    return unmapImpl(as.select(va), va, size, .@"4kb", opts, allocator);
}

/// Unmaps the VA range using 2MiB pages.
pub fn unmap2mb(as: AddressSpace, va: usize, size: usize, opts: UnmapOptions, allocator: PageAllocator) Error!void {
    return unmapImpl(as.select(va), va, size, .@"2mb", opts, allocator);
}

/// Unmaps the VA range using 1GiB pages.
pub fn unmap1gb(as: AddressSpace, va: usize, size: usize, opts: UnmapOptions, allocator: PageAllocator) Error!void {
    return unmapImpl(as.select(va), va, size, .@"1gb", opts, allocator);
}

/// Enable MMU.
pub fn enable(as: AddressSpace, allocator: PageAllocator) void {
    loadSatp(as, allocator);
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

// =============================================================
// Internals
// =============================================================

/// Size of page block.
const Granule = enum {
    @"4kb",
    @"2mb",
    @"1gb",

    fn granule(self: Granule) usize {
        return switch (self) {
            .@"4kb" => size_4k,
            .@"2mb" => size_2mib,
            .@"1gb" => size_1gib,
        };
    }

    fn level(self: Granule) Level {
        return switch (self) {
            .@"4kb" => 3,
            .@"2mb" => 2,
            .@"1gb" => 1,
        };
    }
};

/// Translation level.
///
/// This counts the number of table descents from the top-level table.
const Level = u2;

/// Map the given virtual address to physical address using the given granule size.
///
/// If new table is required to map the range, it is allocated using the given allocator.
fn mapImpl(root: PageTable, arg: MapArgument, mg: Granule, opts: MapOptions, allocator: PageAllocator) Error!void {
    const granule = mg.granule();
    const level = mg.level();

    if (arg.size % size_4k != 0) {
        return Error.InvalidMapping;
    }
    if (opts.exact) {
        if (arg.pa % granule != 0) return Error.InvalidMapping;
        if (arg.va % granule != 0) return Error.InvalidMapping;
        if (arg.size % granule != 0) return Error.InvalidMapping;
    }

    const asize = util.roundup(arg.size, granule);
    const base_va = util.rounddown(arg.va, granule);
    const base_pa = util.rounddown(arg.pa, granule);

    for (0..asize / granule) |i| {
        const cur_pa = base_pa + i * granule;
        const cur_va = base_va + i * granule;
        const entry = try lookupSpawn(
            root._tbl,
            cur_va,
            level,
            allocator,
        );

        const readable = arg.perm.kr or arg.perm.kw or arg.perm.ur or arg.perm.uw;
        const writable = arg.perm.kw or arg.perm.uw;
        const executable = arg.perm.kx or arg.perm.ux;

        entry.* = .{
            .valid = readable or executable,
            .readable = readable,
            .writable = writable,
            .executable = executable,
            .user = arg.perm.ur or arg.perm.uw or arg.perm.ux,
            .global = false,
            .ppn = calcPpn(cur_pa),
        };
    }

    if (opts.flush) {
        tlb.invalidateAll(undefined, .local);
    }
}

/// Changes permissions of an existing virtual address range using the given granule size.
fn remapImpl(root: PageTable, va: usize, size: usize, mg: Granule, perm: Permission, opts: RemapOptions, allocator: PageAllocator) Error!void {
    const granule = mg.granule();
    const level = mg.level();

    if (size % size_4k != 0) return Error.InvalidMapping;
    if (va % granule != 0) return Error.InvalidMapping;
    if (size % granule != 0) return Error.InvalidMapping;

    for (0..size / granule) |i| {
        const entry = try lookupEntry(
            root._tbl,
            va + i * granule,
            level,
            allocator,
        );

        const readable = perm.kr or perm.kw or perm.ur or perm.uw;
        const writable = perm.kw or perm.uw;
        const executable = perm.kx or perm.ux;

        var value = entry.*;
        value.valid = readable or executable;
        value.readable = readable;
        value.writable = writable;
        value.executable = executable;
        value.user = perm.ur or perm.uw or perm.ux;
        entry.* = value;
    }

    if (opts.flush) {
        tlb.invalidateAll(undefined, .local);
    }
}

/// Unmaps the given virtual address range using the given granule size.
fn unmapImpl(root: PageTable, va: usize, size: usize, mg: Granule, opts: UnmapOptions, allocator: PageAllocator) Error!void {
    const granule = mg.granule();
    const level = mg.level();

    if (size % size_4k != 0) return Error.InvalidMapping;
    if (va % granule != 0) return Error.InvalidMapping;
    if (size % granule != 0) return Error.InvalidMapping;

    for (0..size / granule) |i| {
        try lookupInvalidate(
            root._tbl,
            va + i * granule,
            level,
            allocator,
        );
    }

    if (opts.flush) {
        tlb.invalidateAll(undefined, .local);
    }
}

/// Lookup the page table entry for the given virtual address.
///
/// If the descriptor does not exist, spawn a new table descriptor recursively.
fn lookupSpawn(root: []TableEntry, va: usize, level: Level, allocator: PageAllocator) Error!*TableEntry {
    var tbl = root;

    var cur_level: Level = 0;
    while (cur_level < level) : (cur_level += 1) {
        const entry = &tbl[getIndex(cur_level, va)];

        // Spawn a new table.
        if (!entry.valid) {
            const new_tbl = try allocNewTable(allocator);
            const tbl_phys = allocator.translateIntP(new_tbl);
            entry.* = .table(calcPpn(tbl_phys));
        }

        // The region is mapped as a large page.
        if (entry.isLeaf()) {
            return Error.InvalidMapping;
        }

        // Descend to the next level.
        tbl = allocator.translateV(getTable(entry.next()));
    }

    return &tbl[getIndex(level, va)];
}

/// Lookup an existing page table entry for the given virtual address.
fn lookupEntry(root: []TableEntry, va: usize, level: Level, allocator: PageAllocator) Error!*TableEntry {
    var tbl = root;

    var cur_level: Level = 0;
    while (cur_level < level) : (cur_level += 1) {
        const entry = &tbl[getIndex(cur_level, va)];
        if (!entry.valid) {
            return Error.InvalidMapping;
        }
        if (entry.isLeaf()) {
            return Error.InvalidMapping;
        }
        tbl = allocator.translateV(getTable(entry.next()));
    }

    const leaf: *TableEntry = @ptrCast(&tbl[getIndex(level, va)]);
    if (!leaf.valid or !leaf.isLeaf()) {
        return Error.InvalidMapping;
    }

    return leaf;
}

/// Lookup the page table entry for the given virtual address and invalidate it.
fn lookupInvalidate(root: []TableEntry, va: usize, level: Level, allocator: PageAllocator) Error!void {
    const entry = try lookupEntry(
        root,
        va,
        level,
        allocator,
    );
    entry.valid = false;
}

/// Load the root table of the given address space into SATP.
fn loadSatp(as: AddressSpace, allocator: PageAllocator) void {
    const root = as._root orelse @panic("table not present");

    const satp = regs.Satp{
        .asid = 0, // TODO
        .ppn = calcPpn(root.phys(allocator)),
        .mode = .sv48,
    };
    am.csrw(.satp, satp);
    tlb.invalidateAll(as, .local);

    // Check if the SATP value was accepted.
    rtt.expectEqual(satp, am.csrr(.satp));
}

/// Get the index for the given level from the given virtual address for Sv48 paging.
fn getIndex(level: Level, va: usize) usize {
    return (va >> (page_shift_4k + (@as(u6, 3 - level) * 9))) & 0x1FF;
}

/// Calculate the physical page number from the given physical address.
fn calcPpn(pa: usize) u44 {
    return @intCast(pa >> page_shift_4k);
}

/// Get a table that contains the given descriptor.
fn getTable(tbl: anytype) []TableEntry {
    const value = switch (@typeInfo(@TypeOf(tbl))) {
        .pointer => |pointer| switch (pointer.size) {
            .one, .many, .c => @intFromPtr(tbl),
            .slice => @intFromPtr(tbl.ptr),
        },
        else => tbl,
    };

    const aligned = util.rounddown(value, size_4k);
    const ptr: [*]TableEntry = @ptrFromInt(aligned);
    return ptr[0..num_ents];
}

/// Allocate a new page table.
fn allocNewTable(allocator: PageAllocator) Error![]TableEntry {
    const page = try allocator.allocPagesV(1);
    @memset(page, 0);
    return @as([*]TableEntry, @ptrCast(page.ptr))[0..num_ents];
}

/// Check if the given virtual address is in canonical form.
fn isCanonical(va: usize) bool {
    const sign = va >> 47;
    return sign == 0 or sign == 0x1FFFF;
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
    pub fn invalidateAll(_: AddressSpace, scope: Scope) void {
        switch (scope) {
            .local => asm volatile ("sfence.vma" ::: .{ .memory = true }),
            .global => @panic("Global invalidateAll not supported yet"),
        }
    }

    /// Invalidate the TLB entries covering the given virtual address range.
    pub fn invalidateRange(_: AddressSpace, _: usize, _: usize, _: Scope) void {
        @panic(todo);
    }
};

// =============================================================
// RISC-V data structures
// =============================================================

// Number of bits to shift to get the page offset.
const page_shift_4k = 12;
const page_shift_2m = 21;
const page_shift_1g = 30;

// Page sizes in bytes.
const size_4k = 1 << page_shift_4k;
const size_2mib = 1 << page_shift_2m;
const size_1gib = 1 << page_shift_1g;

/// The number of entries in a page table.
const num_ents = size_4k / @sizeOf(TableEntry);
/// The number of entries covering one canonical VA half in the root table.
const root_half_ents = num_ents / 2;

/// Sv48 page table entry.
const TableEntry = packed struct(u64) {
    /// PTE is valid.
    ///
    /// If false, all other bits are don't-cares.
    valid: bool,
    /// Page is readable.
    readable: bool,
    /// Page is writable.
    ///
    /// Writable pages must also be marked as readable.
    writable: bool,
    /// Page is executable.
    executable: bool,
    /// Page is accessible to user mode.
    user: bool,
    /// Global mapping.
    global: bool,
    /// Accessed bit.
    ///
    /// Indicates the page has been read, written, or fetched from since the last time the bit was cleared.
    accessed: bool = true,
    /// Dirty bit.
    ///
    /// Indicates the page has been written to since the last time the bit was cleared.
    dirty: bool = true,
    /// Reserved for software use.
    rsw: u2 = 0,
    /// Physical page number.
    ppn: u44,
    /// Reserved.
    _54: u7 = 0,
    /// Page-based memory types, only when Svpbmt extension is implemented.
    ///
    /// Must be zeroes when Svpbmt is not implemented, or the entry is not leaf.
    pbmt: PbmtAttr = .pma,
    /// NAPOT translation contiguity hint, only when Svnapot extension is implemented.
    ///
    /// Must be zero when Svnapot is not implemented, or the entry is not leaf.
    n: bool = false,

    /// Create a non-leaf entry pointing to the next-level table.
    pub fn table(ppn: u44) TableEntry {
        return .{
            .valid = true,
            .readable = false,
            .writable = false,
            .executable = false,
            .user = false,
            .global = false,
            .accessed = false,
            .dirty = false,
            .ppn = ppn,
        };
    }

    /// Whether this entry is a leaf entry.
    ///
    /// If false, this entry points to the next-level page table.
    pub fn isLeaf(self: TableEntry) bool {
        return self.readable or self.writable or self.executable;
    }

    /// Get the physical address of the next-level page table.
    pub fn next(self: *const TableEntry) usize {
        rtt.expectEqual(true, self.valid);
        rtt.expectEqual(false, self.isLeaf());
        return @as(usize, @intCast(self.ppn)) << page_shift_4k;
    }
};

/// Requested memory attributes for PBMT.
const PbmtAttr = enum(u2) {
    /// Follow PMA.
    pma = 0,
    /// Non-cacheable, idempotent, weakly-ordered, main memory.
    nc = 1,
    /// Non-cacheable, non-idempotent, strongly-ordered, I/O memory.
    io = 2,
    /// Reserved for future use.
    reserved = 3,

    /// Get PBMT attribute from memory attribute.
    ///
    /// TODO: currently no PBMT support, fallback to PMA for all attributes.
    pub fn from(attr: Attribute) PbmtAttr {
        return switch (attr) {
            .device => .pma,
            .normal => .pma,
            .wc => .pma,
            .nc => .pma,
        };
    }
};

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const rtt = common.rtt;
const util = common.util;
const PageAllocator = common.mem.PageAllocator;
const Attribute = common.mem.Attribute;
const Permission = common.mem.Permission;

const am = @import("asm.zig");
const regs = @import("register.zig");
