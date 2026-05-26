//! GIC Interrupt Translation Service (ITS) driver for GICv3.
//!
//! Maps (DeviceID, EventID) pairs to LPI INTIDs and delivers them to redistributors.

pub const Error = PageAllocator.Error;

/// Address of ITS.
var base: Pair(usize) = undefined;
/// If false, target address is the physical address of the Redistributor.
/// If true, target address corresponds to the PE number.
var is_target_addr: bool = false;

/// Command queue.
var cq: Pair([]CommandWord) = undefined;
/// Current command index.
var cmd_idx: usize = 0;

/// Command word type.
const CommandWord = u64;
// The number of command entries in the command queue.
const cmd_entries = mem.size_4kib / @sizeOf(CommandWord);

/// Set the address of ITS.
pub fn setBase(addr: Pair(usize)) void {
    base = addr;
    its.setBase(addr.value);
}

/// Initialize the ITS.
pub fn init(alloc: PageAllocator) Error!void {
    is_target_addr = its.read(Typer).pta == .addr;

    // Allocate CQ.
    cq = blk: {
        const p = try alloc.alloc(CommandWord, cmd_entries);
        @memset(p, 0);
        break :blk .new(p, alloc.translateIntP(p.ptr));
    };

    // Configure CQ.
    its.modify(Cbaser, .{
        .valid = true,
        .size = 0, // 1 page
        .phys = @as(u38, @truncate(cq.phys >> @bitOffsetOf(Cbaser, "phys"))),
    });
    its.modify(Cwriter, .{
        .offset = 0,
    });

    // Allocate device and collection tables.
    try setupBasers(alloc);

    // Enable ITS.
    its.modify(Ctlr, .{
        .enabled = true,
        .umsi_irq = true,
    });
}

/// Check if the target value should be Redistributor physical address.
///
/// If false, the target value is the PE number.
pub fn useRdAddress() bool {
    return is_target_addr;
}

/// Allocate a per-device Interrupt Translation Table page.
///
/// Returns the physical address of the allocated ITT.
pub fn allocItt(alloc: PageAllocator) Error!u64 {
    const page = try alloc.allocPagesV(1);
    @memset(page, 0);
    return alloc.translateIntP(page.ptr);
}

// =============================================================
// Commands
// =============================================================

const Command = enum(u8) {
    /// SYNC.
    sync = 0x05,
    /// MAPD.
    mapd = 0x08,
    /// MAPC.
    mapc = 0x09,
    /// MAPTI.
    mapti = 0x0A,
};

/// MAPC command.
///
/// Maps the collection table entry defined by `icid` to the target Redistributor.
/// If `valid` is false, the mapping is removed.
///
/// `target` is either the physical address of the Redistributor or the PE number.
pub fn mapc(icid: u16, target: u64, valid: bool) void {
    const rdbase = if (is_target_addr)
        target & 0x000_FFFF_FFFF_0000
    else
        target << 16;

    var cmd = [4]u64{ 0, 0, 0, 0 };
    cmd[2] = @as(u64, icid) |
        rdbase |
        (@as(u64, @intFromBool(valid)) << 63);
    submitCmd(cmd, .mapc);
}

/// MAPD command.
///
/// Maps the Device table entry specified by `devid` to its associated ITT `itt`.
/// If `valid` is false, the mapping is removed.
///
/// `size` is the number of EventID that the device will signal.
/// `itt` is the physical address of the pre-allocated ITT.
pub fn mapd(devid: u32, size: usize, itt: usize, valid: bool) void {
    const size_u5 = std.math.log2_int_ceil(u5, size);

    var cmd = [4]u64{ 0, 0, 0, 0 };
    cmd[0] = @as(u64, devid) << 32;
    cmd[1] = @as(u5, @intCast(size_u5 - 1));
    cmd[2] = (itt & 0xFF_FFFF_FFFF) |
        (@as(u64, @intFromBool(valid)) << 63);
    submitCmd(cmd, .mapd);
}

/// MAPTI command.
///
/// Maps the event `event_id` and the device `devid` to its associated ITE, defined by `lpi_id` and `icid`.
pub fn mapti(devid: u32, event_id: u32, lpi_id: u32, icid: u16) void {
    var cmd = [4]u64{ 0, 0, 0, 0 };
    cmd[0] = @as(u64, devid) << 32;
    cmd[1] = (@as(u64, lpi_id) << 32) |
        @as(u64, event_id);
    cmd[2] = icid;
    submitCmd(cmd, .mapti);
}

/// SYNC command.
///
/// Ensures all outstanding ITS operations associated with physical interrupts for the Redistributor are globally observed.
///
/// `target` is either the physical address of the Redistributor or the PE number.
pub fn sync(target: u64) void {
    const rdbase = if (is_target_addr)
        target & 0x000_FFFF_FFFF_0000
    else
        target << 16;
    var cmd = [4]u64{ 0, 0, 0, 0 };
    cmd[2] = rdbase;
    submitCmd(cmd, .sync);

    commit();
    waitIdle();
}

/// Get a physical address of the ITS Translation Register.
pub fn getTranslaterPhys() usize {
    return base.phys + its.getRegisterOffset(Translater);
}

/// Submit a command to the command queue.
///
/// The command is not committed until `commit()` is called.
fn submitCmd(cmd: [4]CommandWord, op: Command) void {
    cq.value[cmd_idx + 0] = cmd[0] | @intFromEnum(op);
    cq.value[cmd_idx + 1] = cmd[1];
    cq.value[cmd_idx + 2] = cmd[2];
    cq.value[cmd_idx + 3] = cmd[3];
    cmd_idx = (cmd_idx + 4) % cmd_entries;
}

/// Update GITS_CWRITER to notify the ITS of newly queued commands.
fn commit() void {
    its.write(Cwriter, cmd_idx * @sizeOf(CommandWord));
}

/// Wait until the ITS finishes processing all commands and is idle.
fn waitIdle() void {
    const target = its.read(Cwriter).offset;
    its.waitFor(Creader, .{
        .offset = target,
    }, null);
}

// =============================================================
// Internals
// =============================================================

/// Set up BASER registers by allocating memory for tables.
///
/// Once a BASER is setup, we don't need to touch it anymore.
fn setupBasers(alloc: PageAllocator) Error!void {
    for (0..8) |i| {
        var baser = getBaserAt(i).*;
        const btype = baser.type;

        if (btype == .device or btype == .collection) {
            const page = try alloc.allocPagesV(1);
            @memset(page, 0);
            const phys = alloc.translateIntP(page.ptr);

            baser.valid = true;
            baser.size = 0;
            baser.page_size = .@"4k";
            baser.phys = @as(u36, @truncate(phys >> @bitOffsetOf(Baser, "phys")));
            getBaserAt(i).* = baser;
        }
    }
}

// =============================================================
// Registers
// =============================================================

var its = mmio.Module(.{ .natural = u64 }, &.{
    .{ 0x0000, Ctlr },
    .{ 0x0008, Typer },
    .{ 0x0080, Cbaser },
    .{ 0x0088, Cwriter },
    .{ 0x0090, Creader },
    .{ 0x0100, mmio.Marker(.baser) },
    .{ 0x10040, Translater },
}){};

fn getBaserAt(index: usize) *volatile Baser {
    return @ptrFromInt(its.getMarkerAddress(.baser) + index * @sizeOf(Baser));
}

/// GITS_CTLR, ITS Control Register.
///
/// Controls the operation of an ITS.
const Ctlr = packed struct(u32) {
    /// Controls whether the ITS is enabled.
    enabled: bool,
    /// Reserved.
    _1: u1 = 0,
    /// Reserved.
    _2: u2 = 0,
    /// Reserved.
    _4: u4 = 0,
    /// Unmapped MSI reporting interrupt enable.
    umsi_irq: bool,
    /// Reserved.
    _9: u22 = 0,
    /// Indicates completion of all ITS operations. RO.
    quiscent: bool,
};

/// GITS_TYPER, ITS Type Register. RO.
///
/// Specifies the features that an ITS supports.
const Typer = packed struct(u64) {
    /// Whether the ITS supports physical LPIs.
    physical: bool,
    /// Reserved.
    _1: u1 = 0,
    /// Cumulative Collection Tables.
    cct: bool,
    /// Reserved.
    _3: u1 = 0,
    /// The number of bytes per translation table entry, minus one.
    itt_entry_size: u4,
    /// The number of EventID bits implemented, minus one.
    id_bits: u5,
    /// The number of DeviceID bits implemented, minus one.
    dev_bits: u5,
    /// SEI support.
    seis: bool,
    /// Physical Target Address.
    pta: enum(u1) { num = 0, addr = 1 },
    /// Reserved.
    _20: u4 = 0,
    /// Hardware Collection Count.
    hcc: u8,
    /// Number of Collection ID bits.
    cid_bits: u4,
    /// Collection ID Limit.
    cil: u1,
    /// Reserved.
    _37: u7 = 0,
    /// Support for reporting receipt of unmapped MSIs.
    umsi: bool,
    /// Support for generationg an interrupt on receiving unmapped MSI.
    umsi_irq: bool,
    /// ITS cache invalidation behavior on disable.
    inv: bool,
    /// Reserved.
    _47: u17 = 0,
};

/// GITS_CBASER, ITS Command Queue Descriptor.
///
/// Specifies the base address and size of the ITS command queue.
const Cbaser = packed struct(u64) {
    /// The number of 4KB pages of physical memory allocated to the CQ, minus one.
    size: u8,
    /// Reserved.
    _8: u2 = 0,
    /// Shareability attributes of accesses to the CQ.
    sh: enum(u2) {
        /// Non-shareable.
        none = 0,
        /// Inner Shareable.
        inner = 1,
        /// Outer Shareable.
        outer = 2,
    },
    /// Physical address of the CQ.
    phys: u40,
    /// Reserved.
    _52: u1 = 0,
    /// The outer cacheability attributes of accesses to the CQ.
    outer_cache: Cacheability,
    /// Reserved.
    _56: u3 = 0,
    /// The inner cacheability attributes of accesses to the CQ.
    inner_cache: Cacheability,
    /// Reserved.
    _62: u1 = 0,
    /// Whether the CQ is valid.
    valid: bool,
};

/// GITS_CWRITER, ITS Write Register.
///
/// Specifies the offset from GITS_CBASER where software writes the next ITS command.
const Cwriter = packed struct(u64) {
    /// If true, restarts the processing of commands by the ITS if it stalled because of errors.
    retry: bool,
    /// Reserved.
    _1: u4 = 0,
    /// Offset from GITS_CBASER.
    offset: u15,
    /// Reserved.
    _20: u44 = 0,
};

/// GITS_CREADER, ITS Read Register. RO.
///
/// Specifies the offset from GITS_CBASER where the ITS reads the next ITS command.
const Creader = packed struct(u64) {
    /// Reports whether the processing of commands is stalled because of a command error.
    stalled: bool,
    /// Reserved.
    _1: u4 = 0,
    /// Offset from GITS_CBASER.
    offset: u15,
    /// Reserved.
    _20: u44 = 0,
};

/// GITS_BASER<n>, ITS Table Descriptors, n=0-7.
///
/// Specifies the base address and size of the ITS tables.
const Baser = packed struct(u64) {
    /// The number of pages of physical memory allocated to the table, minus one.
    size: u8,
    /// The size of page that the table uses.
    page_size: enum(u2) {
        @"4k" = 0,
        @"16k" = 1,
        @"64k" = 2,
    },
    sh: enum(u2) {
        /// Non-shareable.
        none = 0,
        /// Inner Shareable.
        inner = 1,
        /// Outer Shareable.
        outer = 2,
    },
    /// Physical address of the table.
    phys: u36,
    /// The number of bytes per table entry, minus one. RO.
    entry_size: u5,
    /// Outer Cacheability attributes of accesses to the table.
    outer_cache: Cacheability,
    /// The type of entity that requires entries in the corresponding table.
    type: enum(u3) {
        /// Devices.
        device = 1,
        /// vPEs. GICv4 only.
        vpe = 2,
        /// Interrupt collections.
        collection = 4,
    },
    /// Inner Cacheability attributes of accesses to the table.
    inner_cache: Cacheability,
    /// Whether an implemented register specifies a single, flat table or a two-level table.
    indirect: enum(u1) { single = 0, two = 1 },
    /// Software has allocated memory for the table.
    valid: bool,
};

/// GITS_TRANSLATER, ITS Translation Register.
///
/// Written by a requesting Device to signal an interrupt for translation by the ITS.
const Translater = packed struct(u32) {
    /// An identifier corresponding to the interrupt to be translated.
    event_id: u32,
};

const Cacheability = enum(u3) {
    /// Same as another Cacheability.
    same = 0,
    /// Non-cacheable.
    none = 1,
    /// Cacheable, Read-allocate, Write-through.
    c_ra_wt = 2,
    /// Cacheable, Read-allocate, Write-back.
    c_ra_wb = 3,
    /// Cacheable, Write-allocate, Write-through.
    c_wa_wt = 4,
    /// Cacheable, Write-allocate, Write-back.
    c_wa_wb = 5,
    /// Cacheable, Read-allocate, Write-allocate, Write-through.
    c_ra_wa_wt = 6,
    /// Cacheable, Read-allocate, Write-allocate, Write-back.
    c_ra_wa_wb = 7,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const mem = common.mem;
const mmio = common.mmio;
const PageAllocator = mem.PageAllocator;
const Pair = common.Pair;
