pub const Error = error{
    /// Current mapping does not match the requested mapping.
    InvalidMapping,
} || PageAllocator.Error;

/// Page size in bytes.
const page_size = 4 * units.kib;
/// Page size shift.
const page_shift = 12;
/// The number of descriptors in a table.
const num_ents = page_size / @sizeOf(PageDesc);
/// Virtual address space range in bits.
const va_range = 48;

/// Translation level.
///
/// 5-level translation is not supported.
const Level = u2;

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

const Granule = enum {
    @"4kb",
    @"2mb",
    @"1gb",

    fn granule(self: Granule) usize {
        return switch (self) {
            .@"4kb" => page_size,
            .@"2mb" => 2 * units.mib,
            .@"1gb" => 1 * units.gib,
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

/// Describes a pair of page tables.
pub const PageTablePair = struct {
    /// Virtual address of the page table for lower VA range.
    l0: ?PageTable = null,
    /// Virtual address of the page table for higher VA range.
    l1: ?PageTable = null,

    /// Select the page table for the given virtual address.
    pub fn select(self: PageTablePair, va: usize) PageTable {
        const top = va >> 48;
        if (top == 0) {
            rtt.expect(self.l0 != null);
            return self.l0.?;
        } else if (top == 0xFFFF) {
            rtt.expect(self.l1 != null);
            return self.l1.?;
        } else {
            @panic("Non-canonical address to select page table.");
        }
    }
};

/// Describes a single root page table.
pub const PageTable = struct {
    /// Virtual address of the page table.
    _tbl: []TableDesc,

    pub fn phys(self: PageTable, allocator: PageAllocator) usize {
        return @intFromPtr(allocator.translateP(self._tbl).ptr);
    }
};

/// Allocate a new root page table.
pub fn createPageTable(allocator: PageAllocator) Error!PageTable {
    return .{ ._tbl = try allocNewTable(allocator, TableDesc) };
}

/// Allocate a new pair of root page tables.
pub fn createPageTablePair(allocator: PageAllocator) Error!PageTablePair {
    return .{
        .l0 = try createPageTable(allocator),
        .l1 = try createPageTable(allocator),
    };
}

/// Maps the VA to PA using 4KiB pages.
pub fn map4kb(pt: PageTablePair, arg: MapArgument, opts: MapOptions, allocator: PageAllocator) Error!void {
    return mapImpl(pt.select(arg.va), arg, .@"4kb", opts, allocator);
}

/// Maps the VA to PA using 2MiB pages.
pub fn map2mb(pt: PageTablePair, arg: MapArgument, opts: MapOptions, allocator: PageAllocator) Error!void {
    return mapImpl(pt.select(arg.va), arg, .@"2mb", opts, allocator);
}

/// Maps the VA to PA using 1GiB pages.
pub fn map1gb(pt: PageTablePair, arg: MapArgument, opts: MapOptions, allocator: PageAllocator) Error!void {
    return mapImpl(pt.select(arg.va), arg, .@"1gb", opts, allocator);
}

/// Unmaps the VA range using 4KiB pages.
pub fn unmap4kb(pt: PageTablePair, va: usize, size: usize, allocator: PageAllocator) Error!void {
    return unmapImpl(pt.select(va), va, size, .@"4kb", allocator);
}

/// Unmaps the VA range using 2MiB pages.
pub fn unmap2mb(pt: PageTablePair, va: usize, size: usize, allocator: PageAllocator) Error!void {
    return unmapImpl(pt.select(va), va, size, .@"2mb", allocator);
}

/// Unmaps the VA range using 1GiB pages.
pub fn unmap1gb(pt: PageTablePair, va: usize, size: usize, allocator: PageAllocator) Error!void {
    return unmapImpl(pt.select(va), va, size, .@"1gb", allocator);
}

fn mapImpl(root: PageTable, arg: MapArgument, mg: Granule, opts: MapOptions, allocator: PageAllocator) Error!void {
    const granule = mg.granule();
    const level = mg.level();

    if (arg.size % page_size != 0) return error.InvalidArgument;
    if (opts.exact) {
        if (arg.pa % granule != 0) return error.InvalidArgument;
        if (arg.va % granule != 0) return error.InvalidArgument;
        if (arg.size % granule != 0) return error.InvalidArgument;
    }

    const asize = util.roundup(arg.size, granule);
    const page_type: @FieldType(PageDesc, "type") = if (level == 3) .page else .block;

    const base_pa = util.rounddown(arg.pa, granule);
    const base_va = util.rounddown(arg.va, granule);

    for (0..asize / granule) |i| {
        const cur_pa = base_pa + i * granule;
        const cur_va = base_va + i * granule;
        const desc = try lookupSpawn(root._tbl, cur_va, level, allocator);

        desc.* = PageDesc{
            .valid = true,
            .type = page_type,
            .lattr = LowerAttr{
                .memattr = getAttrIndex(arg.attr),
                .ap = Perm.from(arg.perm),
                .sh = .inner,
            },
            .oa = @truncate(cur_pa >> page_shift),
            .uattr = UpperAttr{
                .dbm = false,
                .contiguous = false,
                .pxn = !arg.perm.kx,
                .uxn = !arg.perm.ux,
            },
        };
    }

    flush();
}

fn unmapImpl(root: PageTable, va: usize, size: usize, mg: Granule, allocator: PageAllocator) Error!void {
    const granule = mg.granule();
    const level = mg.level();

    if (size % page_size != 0) return error.InvalidArgument;
    if (va % granule != 0) return error.InvalidArgument;
    if (size % granule != 0) return error.InvalidArgument;

    for (0..size / granule) |i| {
        const cur_va = va + i * granule;
        try lookupInvalidate(root._tbl, cur_va, level, allocator);
    }

    flush();
}

/// Lookup the page descriptor for the given virtual address and invalidate it.
fn lookupInvalidate(root: []TableDesc, va: usize, level: Level, allocator: PageAllocator) Error!void {
    var tbl = root;

    var cur_level: Level = 0;
    while (cur_level < level) : (cur_level += 1) {
        const desc = &tbl[getIndex(cur_level, va)];

        if (!desc.valid) return error.InvalidMapping;
        if (!desc.table) return error.InvalidMapping;

        tbl = allocator.translateV(getTable(TableDesc, desc.next()));
    }

    const leaf: *PageDesc = @ptrCast(&tbl[getIndex(level, va)]);
    if (!leaf.valid) return error.InvalidMapping;
    leaf.valid = false;
}

/// Enable MMU.
pub fn enable(pt: PageTablePair, allocator: PageAllocator) void {
    rtt.expect(pt.l0 != null);
    rtt.expect(pt.l1 != null);

    const l0_0_phys = pt.l0.?.phys(allocator);
    const l0_1_phys = pt.l1.?.phys(allocator);

    // Configure TCR_EL1.
    const tcr = regs.Tcr{
        .t0sz = 64 - va_range,
        .irgn0 = .wbrawac,
        .orgn0 = .wbrawac,
        .sh0 = .inner,
        .tg0 = .size_4kib,
        .t1sz = 64 - va_range,
        .a1 = 0,
        .irgn1 = .wbrawac,
        .orgn1 = .wbrawac,
        .sh1 = .inner,
        .tg1 = .size_4kib,
        .ips = 0b101, // 48-bit PA
    };
    am.msr(.tcr_el1, tcr);

    // Configure MAIR_EL1.
    const mair = std.mem.zeroInit(regs.Mair, .{
        .attr0 = 0b0000_0000, // Device-nGnRnE
        .attr1 = 0b1111_1111, // Normal: Outer Write-Back Write-Allocate, Inner Write-Back Write-Allocate
    });
    am.msr(.mair_el1, mair);

    // Set TTBR0_EL1 and TTBR1_EL1.
    const ttbr0 = regs.Ttbr0El1{
        .addr = @intCast(l0_0_phys),
        .asid = 0,
    };
    const ttbr1 = regs.Ttbr1El1{
        .addr = @intCast(l0_1_phys),
        .asid = 0,
    };
    am.msr(.ttbr0_el1, ttbr0);
    am.msr(.ttbr1_el1, ttbr1);

    // Configure SCTLR_EL1.
    var sctlr = am.mrs(.sctlr_el1);
    sctlr.i = true; // Enable instruction cache
    sctlr.c = true; // Enable data cache
    sctlr.m = true; // Enable MMU

    asm volatile (
        \\isb
        \\dsb sy
        \\tlbi vmalle1
        \\dsb sy
        \\isb
        \\msr SCTLR_EL1, %[sctlr]
        :
        : [sctlr] "r" (@as(u64, @bitCast(sctlr))),
    );
}

/// Switch the user-space page table (TTBR0_EL1) to the given page table.
///
/// If `l0` is null, TTBR0_EL1 is cleared.
/// TLB is flushed after the switch.
pub fn switchUserTable(l0: ?PageTable, allocator: PageAllocator) void {
    am.msr(.ttbr0_el1, regs.Ttbr0El1{
        .addr = if (l0) |tbl| @intCast(tbl.phys(allocator)) else 0,
        .asid = 0,
    });

    // Should use ASID to avoid flushing the entire TLB, but it's not implemented yet.
    flush();
}

/// Flush all TLB entries.
fn flush() void {
    asm volatile (
        \\isb
        \\dsb sy
        \\tlbi vmalle1
        \\dsb sy
        \\isb
    );
}

/// Translate the given virtual address to physical address by walking the page tables.
pub fn translateWalk(pt: PageTable, va: usize, allocator: PageAllocator) ?usize {
    var tbl = allocator.translateV(pt._tbl);

    var cur_level: usize = 0;
    while (cur_level <= 3) : (cur_level += 1) {
        const tdesc: *const TableDesc = &tbl[getIndex(@intCast(cur_level), va)];
        const pdesc: *const PageDesc = @ptrCast(tdesc);

        if (!tdesc.valid) {
            return null;
        }

        if (cur_level == 3 or pdesc.type == .block) {
            const offset_bits: u6 = @intCast(page_shift + (3 - cur_level) * 9);
            const offset_mask = (@as(usize, 1) << offset_bits) - 1;
            return (@as(usize, @intCast(pdesc.oa)) << page_shift) | (va & offset_mask);
        }

        // Descend to the next level.
        tbl = getTable(TableDesc, allocator.translateV(tdesc.next()));
    }

    return null;
}

/// Get the physical address corresponding to the given virtual address.
pub fn getPhysicalAddress(va: usize) usize {
    const ret = asm volatile (
        \\at S1E1R, %[va]
        \\mrs %[pa], PAR_EL1
        : [pa] "=r" (-> usize),
        : [va] "r" (va),
    );

    rtt.expect(ret & 1 == 0);
    return (ret & 0x00FF_FFFF_FFFF_F000) + (va & 0xFFF);
}

/// Lookup the page descriptor for the given virtual address.
///
/// If the descriptor does not exist, spawn a new table descriptor recursively.
fn lookupSpawn(root: []TableDesc, va: usize, level: Level, allocator: PageAllocator) Error!*PageDesc {
    var tbl = root;

    var cur_level: Level = 0;
    while (cur_level < level) : (cur_level += 1) {
        const desc = &tbl[getIndex(cur_level, va)];

        // Spawn a new table.
        if (!desc.valid) {
            const new_tbl = try allocNewTable(allocator, TableDesc);
            desc.* = TableDesc.new(@intFromPtr(allocator.translateP(new_tbl).ptr));
        }

        // The region is already mapped as a block or page.
        if (!desc.table) {
            return Error.InvalidMapping;
        }

        // Descend to the next level.
        tbl = allocator.translateV(getTable(TableDesc, desc.next()));
    }

    return @ptrCast(&tbl[getIndex(level, va)]);
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

    const aligned = util.rounddown(value, page_size);
    const ptr: [*]T = @ptrFromInt(aligned);
    return ptr[0..num_ents];
}

/// Get the index for the given level from the given virtual address.
fn getIndex(level: Level, va: usize) usize {
    return (va >> (12 + (@as(u6, 3 - level) * 9))) & 0x1FF;
}

/// Allocate a new table of the specified descriptor type.
fn allocNewTable(allocator: PageAllocator, T: type) Error![]T {
    const page = try allocator.allocPagesV(1);
    const table = getTable(T, page);

    @memset(table, std.mem.zeroInit(T, .{ .valid = false }));

    return table;
}

/// Get the MAIR index for the given attribute.
fn getAttrIndex(attr: Attribute) u3 {
    return switch (attr) {
        .device => 0,
        .normal => 1,
    };
}

// =============================================================
// Aarch64 structures
// =============================================================

/// Table descriptor for Stage 1 translation.
///
/// Supposing:
/// - Indirect access permissions are disabled.
/// - 4KiB translation granule is used.
const TableDesc = packed struct(u64) {
    /// Valid descriptor.
    valid: bool = true,
    /// Table descriptor.
    ///
    /// True for lookup levels less than lookup level 3.
    table: bool = true,
    /// Ignored.
    _2: u6 = 0,
    /// Ignored.
    _8: u2 = 0,
    /// Ignored when Hardware managed Table descriptor Access flag is not enabled.
    _10: u1 = 0,
    /// Ignored.
    _11: u1 = 0,
    /// Next level table address.
    ///
    /// The valid bits depend on the OA size.
    nlta: u38,
    /// Reserved.
    _50: u1 = 0,
    /// Ignored.
    _51: u1 = 0,
    /// Ignored when PnCH is 0.
    _52: u1 = 0,
    /// Ignored.
    _53: u6 = 0,
    /// Attributes (not used).
    attributes: u5 = 0,

    pub fn new(tbl: usize) TableDesc {
        return TableDesc{
            .valid = true,
            .table = true,
            .nlta = @truncate(tbl >> 12),
        };
    }

    pub fn next(self: TableDesc) usize {
        return @as(usize, self.nlta) << 12;
    }
};

/// Page or Block descriptor for Stage 1 translation.
///
/// Supposing:
/// - Indirect access permissions are disabled.
/// - 4KiB translation granule is used.
const PageDesc = packed struct(u64) {
    /// Valid descriptor.
    valid: bool = true,
    /// Page descriptor or Block descriptor.
    type: enum(u1) { block = 0, page = 1 },
    /// Lower attributes.
    lattr: LowerAttr,
    /// Output address.
    ///
    /// The valid bits depend on the OA size.
    oa: u38,
    /// Reserved.
    _50: u1 = 0,
    /// Upper attributes.
    uattr: UpperAttr,
};

/// Lower attributes for Stage 1 page descriptor.
///
/// Supposing:
/// - Indirect access permissions are disabled.
/// - 4KiB translation granule is used.
const LowerAttr = packed struct(u10) {
    /// Memory type and cacheability attribute for Stage 1.
    memattr: u3,
    /// Non-secure.
    ///
    /// Reserved when the access is from Non-secure state.
    ns: u1 = 0,
    /// Access permission.
    ap: Perm,
    /// Shareability.
    sh: Shareability,
    /// Access flag.
    af: bool = true,
    /// Reserved.
    _9: u1 = 0,
};

/// Upper attributes for Stage 1 page descriptor.
///
/// Supposing:
/// - Indirect access permissions are disabled.
/// - 4KiB translation granule is used.
const UpperAttr = packed struct(u13) {
    /// Dirty bit modifier.
    dbm: bool,
    /// Contiguous bit.
    contiguous: bool,
    /// Privileged Execute-never.
    pxn: bool,
    /// Unprivileged Execute-never.
    uxn: bool,
    /// Ignored.
    _4: u1 = 0,
    /// Reserved for software use.
    sw: u3 = 0,
    /// Ignored.
    _8: u1 = 0,
    /// Ignored.
    _9: u3 = 0,
    /// Ignored.
    _12: u1 = 0,
};

/// Stage 1 Shareability.
const Shareability = enum(u2) {
    /// Non-shareable.
    non = 0b00,
    /// Reserved.
    _reserved = 0b01,
    /// Outer Sharable.
    outer = 0b10,
    /// Inner Sharable.
    inner = 0b11,
};

/// Stage 1 data access permissions.
const Perm = enum(u2) {
    /// Privileged Read, Privileged Write.
    prpw = 0b00,
    /// Privileged Read, Privileged Write, Unprivileged Read, Unprivileged Write.
    prpwrw = 0b01,
    /// Privileged Read-Only.
    pr = 0b10,
    /// Privileged Read-Only, Unprivileged Read-Only.
    prr = 0b11,

    /// Convert the given permission to Stage 1 data access permission.
    pub fn from(perm: Permission) Perm {
        if (perm.kr and perm.kw and perm.ur and perm.uw) {
            return .prpwrw;
        } else if (perm.kr and perm.kw and !perm.ur and !perm.uw) {
            return .prpw;
        } else if (perm.kr and !perm.kw and perm.ur and !perm.uw) {
            return .prr;
        } else if (perm.kr and !perm.kw and !perm.ur and !perm.uw) {
            return .pr;
        } else {
            @panic("Invalid permission combination.");
        }
    }
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
const regs = @import("register.zig");
