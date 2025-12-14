pub const Error = PageAllocator.Error;

/// Page size in bytes.
const page_size = 4 * units.kib;
/// The number of descriptors in a table.
const num_ents = page_size / @sizeOf(PageDesc);
/// Virtual address space range in bits.
const va_range = 48;

/// Table pointed to by TTBR0_EL1.
var l0_0: []TableDesc = undefined;
/// Table pointed to by TTBR1_EL1.
var l0_1: []TableDesc = undefined;

/// Translation level.
///
/// 5-level translation is not supported.
const Level = u2;

/// Page attribute for mapping.
pub const Attribute = enum(u3) {
    /// Device memory.
    ///
    /// Strongly ordered, non-cacheable.
    device = 0,
    /// Normal memory.
    ///
    /// Cacheable.
    normal = 1,
};

/// Initialize MMU with the given level 0 table address.
///
/// MMU is not enabled by this function.
pub fn init(allocator: PageAllocator) Error!void {
    l0_0 = try allocNewTable(allocator, TableDesc);
    l0_1 = try allocNewTable(allocator, TableDesc);
}

/// Maps the VA to PA using 1GiB pages.
pub fn map1gb(pa: usize, va: usize, size: usize, attr: Attribute, allocator: PageAllocator) Error!void {
    if (pa % page_size != 0) return Error.InvalidArgument;
    if (va % page_size != 0) return Error.InvalidArgument;
    if (size % page_size != 0) return Error.InvalidArgument;

    const l0 = getRoot(va);
    const asize = util.roundup(size, units.gib);
    const l0tbl = getTable(TableDesc, l0);

    for (0..asize / units.gib) |i| {
        const cur_pa = pa + i * page_size;
        const cur_va = va + i * page_size;

        const l0desc = &l0tbl[getIndex(0, cur_va)];
        if (!l0desc.valid or !l0desc.table) {
            const l1tbl = try allocNewTable(allocator, PageDesc);
            l0desc.* = TableDesc.new(
                @intFromPtr(allocator.translateP(l1tbl).ptr),
            );
        }

        const l1tbl = getTable(PageDesc, l0desc.next());
        const l1desc = &l1tbl[getIndex(1, cur_va)];

        l1desc.* = PageDesc{
            .valid = true,
            .type = .block,
            .lattr = LowerAttr{
                .memattr = @intFromEnum(attr),
                .ap = .prpw,
                .sh = .inner,
            },
            .oa = @truncate(cur_pa >> 12),
            .uattr = UpperAttr{
                .dbm = false,
                .contiguous = false,
                .pxn = false,
                .uxn = false,
            },
        };
    }
}

/// Enable MMU.
pub fn enable(allocator: PageAllocator) void {
    const l0_0_phys = @intFromPtr(allocator.translateP(l0_0).ptr);
    const l0_1_phys = @intFromPtr(allocator.translateP(l0_1).ptr);

    // Configure TCR_EL1.
    const tcr = regs.Tcr{
        .t0sz = 64 - va_range,
        .irgn0 = .nc,
        .orgn0 = .nc,
        .sh0 = .inner,
        .tg0 = .size_4kib,
        .t1sz = 64 - va_range,
        .a1 = 0,
        .irgn1 = .nc,
        .orgn1 = .nc,
        .sh1 = .inner,
        .tg1 = .size_4kib,
        .ips = 0b101, // 48-bit PA
    };
    am.msr(.tcr_el1, tcr);

    // Configure MAIR_EL1.
    const mair = std.mem.zeroInit(regs.Mair, .{
        .attr0 = 0b0000_0000, // Device-nGnRnE
        .attr1 = 0b0100_0100, // Normal memory
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
    am.msr(.sctlr_el1, sctlr);
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

/// Get the root page table corresponding to the given virtual address.
fn getRoot(va: usize) []TableDesc {
    if (va >> 48 == 0) {
        return l0_0;
    } else {
        return l0_1;
    }
}

// =============================================================
// Aarch64 structures
// =============================================================

/// Abstract descriptor.
const AnyDesc = packed struct(u64) {
    /// Valid descriptor.
    valid: bool,
    // Reserved.
    _rsvd: u63 = 0,
};

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
    _rsvd0: u6 = 0,
    /// Ignored.
    _rsvd1: u2 = 0,
    /// Ignored when Hardware managed Table descriptor Access flag is not enabled.
    _rsvd2: u1 = 0,
    /// Ignored.
    _rsvd3: u1 = 0,
    /// Next level table address.
    ///
    /// The valid bits depend on the OA size.
    nlta: u38,
    /// Reserved.
    _rsvd4: u1 = 0,
    /// Ignored.
    _rsvd5: u1 = 0,
    /// Ignored when PnCH is 0.
    _rsvd6: u1 = 0,
    /// Ignored.
    _rsvd7: u6 = 0,
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
    _rsvd0: u1 = 0,
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
    _rsvd1: u1 = 0,
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
    _rsvd1: u1 = 0,
    /// Reserved for software use.
    sw: u3 = 0,
    /// Ignored.
    _rsvd2: u1 = 0,
    /// Ignored.
    _rsvd3: u3 = 0,
    /// Ignored.
    _rsvd4: u1 = 0,
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
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const units = common.units;
const util = common.util;
const PageAllocator = common.PageAllocator;

const am = @import("asm.zig");
const regs = @import("register.zig");
