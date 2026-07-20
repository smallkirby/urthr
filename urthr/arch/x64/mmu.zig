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
    /// The single root table shared by both VA halves.
    _root: ?PageTable = null,
    /// Whether the lower VA half of the root table currently holds a user mapping.
    _has_user: bool = false,

    /// Select the page table for the given virtual address.
    pub fn select(self: AddressSpace, va: usize) PageTable {
        rtt.expect(isCanonical(va));
        return self._root orelse @panic("table not present");
    }

    /// Returns whether this address space has no user (lower VA range) mapping.
    pub fn isKernelOnly(self: AddressSpace) bool {
        return !self._has_user;
    }

    /// Returns a copy of this address space with the user mapping dropped.
    ///
    /// The returned address space still shares the same root table.
    pub fn kernelOnly(self: AddressSpace) AddressSpace {
        return .{ ._root = self._root, ._has_user = false };
    }

    /// Returns a copy of this address space with the user table replaced.
    pub fn withUserTable(_: AddressSpace, _: PageTable) AddressSpace {
        @panic("unimplemented: withUserTable");
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
    return .{ ._tbl = try allocNewTable(allocator, TableEntry) };
}

/// Allocate a new address space with a fresh root table.
pub fn createAddressSpace(allocator: PageAllocator) Error!AddressSpace {
    return .{ ._root = try createPageTable(allocator) };
}

/// Fix up the table addresses held by the address space.
///
/// This function is intended to be called after identity-mapping is unmapped
/// to fix up the virtual address of the page tables.
pub fn relocate(as: *AddressSpace, allocator: PageAllocator) void {
    if (as._root) |*t| t._tbl = allocator.translateV(t._tbl);
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
pub fn remap4kb(_: AddressSpace, _: usize, _: usize, _: Permission, _: PageAllocator) Error!void {
    @panic("unimplemented");
}

/// Unmaps the VA range using 4KiB pages.
pub fn unmap4kb(as: AddressSpace, va: usize, size: usize, allocator: PageAllocator) Error!void {
    return unmapImpl(as.select(va), va, size, .@"4kb", allocator);
}

/// Unmaps the VA range using 2MiB pages.
pub fn unmap2mb(as: AddressSpace, va: usize, size: usize, allocator: PageAllocator) Error!void {
    return unmapImpl(as.select(va), va, size, .@"2mb", allocator);
}

/// Unmaps the VA range using 1GiB pages.
pub fn unmap1gb(as: AddressSpace, va: usize, size: usize, allocator: PageAllocator) Error!void {
    return unmapImpl(as.select(va), va, size, .@"1gb", allocator);
}

/// Enable MMU.
pub fn enable(as: AddressSpace, allocator: PageAllocator) void {
    rtt.expect(as._root != null);

    // Enable NX bits.
    var efer = am.rdmsr(.efer);
    efer.nxe = true;
    am.wrmsr(.efer, efer);

    // Load CR3.
    const cr3 = Cr3{
        .pcid = 0, // TODO
        .phys = @truncate(as._root.?.phys(allocator) >> page_shift_4k),
        .lam57 = false,
        .lam48 = false,
    };
    asm volatile (
        \\mov %[cr3], %%cr3
        :
        : [cr3] "r" (cr3),
        : .{ .memory = true });
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
/// This counts the number of table descents from the level-4 table.
const Level = u2;

/// Attribute bits for the page table entry.
const AttrBits = struct {
    /// Write-through.
    pwt: bool,
    /// Page-level cache disable.
    pcd: bool,
};

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
    const attr = getAttrBits(arg.attr);

    for (0..asize / granule) |i| {
        const cur_pa = base_pa + i * granule;
        const cur_va = base_va + i * granule;
        const entry = try lookupSpawn(
            root._tbl,
            cur_va,
            level,
            allocator,
        );

        entry.* = .{
            .rw = arg.perm.kw or arg.perm.uw,
            .us = arg.perm.ur or arg.perm.uw,
            .pwt = attr.pwt,
            .pcd = attr.pcd,
            .ps = level != 3, // For 4KiB PTE, this bit is used as PAT.
            .phys = @truncate(cur_pa >> page_shift_4k),
            .xd = !(arg.perm.kx or arg.perm.ux),
        };
    }

    flushAll();
}

/// Unmaps the given virtual address range using the given granule size.
fn unmapImpl(root: PageTable, va: usize, size: usize, mg: Granule, allocator: PageAllocator) Error!void {
    const granule = mg.granule();
    const level = mg.level();

    if (size % size_4k != 0) {
        return Error.InvalidMapping;
    }
    if (va % granule != 0) {
        return Error.InvalidMapping;
    }
    if (size % granule != 0) {
        return Error.InvalidMapping;
    }

    for (0..size / granule) |i| {
        try lookupInvalidate(
            root._tbl,
            va + i * granule,
            level,
            allocator,
        );
    }

    flushAll();
}

/// Lookup the page table entry for the given virtual address and invalidate it.
fn lookupInvalidate(root: []TableEntry, va: usize, level: Level, allocator: PageAllocator) Error!void {
    const entry = try lookupEntry(
        root,
        va,
        level,
        allocator,
    );
    entry.present = false;
}

/// Lookup an existing page table entry for the given virtual address.
fn lookupEntry(root: []TableEntry, va: usize, level: Level, allocator: PageAllocator) Error!*PageEntry {
    var tbl = root;

    var cur_level: Level = 0;
    while (cur_level < level) : (cur_level += 1) {
        const entry = &tbl[getIndex(cur_level, va)];
        if (!entry.present) {
            return Error.InvalidMapping;
        }
        if (entry.ps) {
            return Error.InvalidMapping;
        }
        tbl = allocator.translateV(getTable(TableEntry, entry.next()));
    }

    const leaf: *PageEntry = @ptrCast(&tbl[getIndex(level, va)]);
    if (!leaf.present) return Error.InvalidMapping;

    return leaf;
}

/// Lookup the page table entry for the given virtual address.
///
/// If the descriptor does not exist, spawn a new table descriptor recursively.
fn lookupSpawn(root: []TableEntry, va: usize, level: Level, allocator: PageAllocator) Error!*PageEntry {
    var tbl = root;

    var cur_level: Level = 0;
    while (cur_level < level) : (cur_level += 1) {
        const entry = &tbl[getIndex(cur_level, va)];

        // Spawn a new table.
        if (!entry.present) {
            const new_tbl = try allocNewTable(
                allocator,
                TableEntry,
            );
            const tbl_phys = allocator.translateP(new_tbl).ptr;
            entry.* = .{
                .phys = @truncate(@intFromPtr(tbl_phys) >> page_shift_4k),
            };
        }

        // The region is already mapped as a large page.
        if (entry.ps) {
            return Error.InvalidMapping;
        }

        // Descend to the next level.
        tbl = allocator.translateV(getTable(TableEntry, entry.next()));
    }

    return @ptrCast(&tbl[getIndex(level, va)]);
}

/// Get the index for the given level from the given virtual address.
fn getIndex(level: Level, va: usize) usize {
    return (va >> (page_shift_4k + (@as(u6, 3 - level) * 9))) & 0x1FF;
}

/// Flush all TLB entries by reloading CR3.
fn flushAll() void {
    const cr3 = asm volatile (
        \\mov %%cr3, %[out]
        : [out] "=r" (-> u64),
    );
    asm volatile (
        \\mov %[in], %%cr3
        :
        : [in] "r" (cr3),
        : .{ .memory = true });
}

/// Get the cacheability bits for the given attribute.
fn getAttrBits(attr: Attribute) AttrBits {
    return switch (attr) {
        // Normal memory.
        .normal => .{ .pwt = false, .pcd = false },
        // Device memory.
        .device => .{ .pwt = false, .pcd = true },
        // Write-combining.
        // TODO: Use PAT to implement write-combining.
        .wc => .{ .pwt = false, .pcd = true },
        // Non-cacheable.
        // TODO: Use PAT to implement non-cacheable.
        .nc => .{ .pwt = false, .pcd = true },
    };
}

/// Check if the given virtual address is in canonical form.
fn isCanonical(va: usize) bool {
    const sign = va >> 47;
    return sign == 0 or sign == 0x1ffff;
}

/// Get a table of the specified descriptor type.
fn getTable(T: type, tbl: anytype) []T {
    const value = switch (@typeInfo(@TypeOf(tbl))) {
        .pointer => |pointer| switch (pointer.size) {
            .one, .many, .c => @intFromPtr(tbl),
            .slice => @intFromPtr(tbl.ptr),
        },
        else => tbl,
    };

    const aligned = util.rounddown(value, size_4k);
    const ptr: [*]T = @ptrFromInt(aligned);
    return ptr[0..num_ents];
}

/// Allocate a new table of the specified descriptor type.
fn allocNewTable(allocator: PageAllocator, T: type) Error![]T {
    const page = try allocator.allocPagesV(1);
    const table = getTable(T, page);

    @memset(table, std.mem.zeroInit(T, .{ .present = false }));

    return table;
}

// =============================================================
// x64 data structures
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

/// Entry that references the next-level page table.
const TableEntry = packed struct(u64) {
    /// Present.
    present: bool = true,
    /// Read / Write.
    ///
    /// If set to false, write access is not allowed to the region.
    rw: bool = true,
    /// User / Supervisor.
    ///
    /// If set to false, user-mode access is not allowed to the region.
    us: bool = true,
    /// Page-level writh-through.
    pwt: bool = false,
    /// Page-level cache disable.
    pcd: bool = false,
    /// Accessed.
    accessed: bool = false,
    /// Ignored.
    _6: u1 = 0,
    /// Page Size.
    ///
    /// Must be false.
    ps: bool = false,
    /// Ignored.
    _8: u4 = 0,
    /// 4KB aligned address of the page table this entry references.
    phys: u35,
    /// Reserved.
    _47: u16 = 0,
    /// Execute Disable.
    xd: bool = false,

    /// Physical address of the page table this entry references.
    pub fn next(self: TableEntry) usize {
        return @as(usize, self.phys) << page_shift_4k;
    }
};

/// Entry that maps a physical page.
const PageEntry = packed struct(u64) {
    /// Present.
    present: bool = true,
    /// Read / Write.
    ///
    /// If set to false, write access is not allowed to the region.
    rw: bool,
    /// User / Supervisor.
    ///
    /// If set to false, user-mode access is not allowed to the region.
    us: bool,
    /// Page-level writh-through.
    pwt: bool = false,
    /// Page-level cache disable.
    pcd: bool = false,
    /// Accessed.
    accessed: bool = false,
    /// Dirty bit.
    ///
    /// Indicates whether software has written to the page.
    dirty: bool = false,
    /// Page Size.
    ///
    /// For 4KiB PTE, this bit is used as PAT.
    ps: bool = true,
    /// Ignored when CR4.PGE != 1.
    global: bool = true,
    /// Ignored
    _9: u3 = 0,
    /// Physical address of the page.
    phys: u35,
    /// Reserved.
    _47: u16 = 0,
    /// Execute Disable.
    xd: bool = false,
};

/// CR3 register.
const Cr3 = packed struct(u64) {
    /// PCID.
    pcid: u12,
    /// Physical address of the level-4 page table.
    phys: u35,
    /// Reserved.
    _47: u14 = 0,
    /// Enable LAM57 for user pointers.
    lam57: bool = false,
    /// Enable LAM48 for user pointers.
    lam48: bool = false,
    /// Reserved.
    _63: u1 = 0,
};

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
const am = @import("asm.zig");
