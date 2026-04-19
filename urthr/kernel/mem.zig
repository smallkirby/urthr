pub const Error = common.mem.Error;

pub const vallocator = @import("mem/vallocator.zig");
pub const vmap = @import("mem/vmemmap.zig");

/// Virtual address type.
pub const Virt = usize;
/// Physical address type.
pub const Phys = usize;

/// Buddy allocator instance.
var buddy_allocator: BuddyAllocator = undefined;
/// Bin allocator instance.
var bin_allocator: BinAllocator = undefined;
/// VM allocator instance.
var phys_allocator: PhysAllocator = undefined;
/// Init task's page table.
var init_pt: arch.mmu.PageTablePair = .{};

/// Initialize memory management.
///
/// This kernel creates new MMU mapping.
pub fn init() Error!void {
    const allocator = urd.boot.getAllocator().interface();

    // Allocate kernel root page table and init task's user page table.
    init_pt = try arch.mmu.createPageTablePair(allocator);

    // Kernel mapping: 2MiB granule, RWX, normal.
    log.debug("Mapping kernel.", .{});
    {
        rtt.expectEqual(0, pmap.kernel % size_2mib);
        rtt.expectEqual(0, vmap.kernel.start % size_2mib);
        try arch.mmu.map2mb(init_pt, .{
            .pa = pmap.kernel,
            .va = vmap.kernel.start,
            .size = util.roundup(kernelSize(), 2 * units.mib),
            .perm = .kernel_rwx,
            .attr = .normal,
        }, .{}, allocator);
    }

    // Linear mapping: 1GiB granule, RW, normal.
    log.debug("Mapping linear memory.", .{});
    {
        for (pmap.drams) |dram| {
            try arch.mmu.map1gb(init_pt, .{
                .pa = dram.start,
                .va = vmap.linear.start + dram.start,
                .size = dram.size(),
                .perm = .kernel_rw,
                .attr = .normal,
            }, .{ .exact = false }, allocator);
        }
    }

    // Temporary device identity mapping: 4KiB granule, RW, device.
    log.debug("Mapping device memory.", .{});
    {
        for (board.getTempMaps()) |range| {
            try arch.mmu.map4kb(init_pt, .{
                .pa = range.start,
                .va = range.start,
                .size = range.size(),
                .perm = .kernel_rw,
                .attr = .device,
            }, .{}, allocator);
        }
    }

    // Switch to the new page table.
    log.debug("Switching to new page table.", .{});
    arch.mmu.enable(init_pt, allocator);
}

/// Initialize allocators.
pub fn initAllocators() void {
    // Page allocator.
    const avails = board.memmap.drams;
    var reserveds = [_]Range{
        // Kernel image
        .{
            .start = pmap.kernel,
            .end = pmap.kernel + kernelSize(),
        },
        // Early allocator region
        urd.boot.getAllocator().getUsedRegion(),
    };
    buddy_allocator.init(&avails, &reserveds, log.debug);

    // Update page table virtual address.
    init_pt.l0.?._tbl = buddy_allocator.interface().translateV(init_pt.l0.?._tbl);
    init_pt.l1.?._tbl = buddy_allocator.interface().translateV(init_pt.l1.?._tbl);

    // Bin allocator.
    bin_allocator.init(getPageAllocator());

    // I/O allocator.
    phys_allocator.init();

    // Now then, boot allocator is no longer needed.
}

/// Initialize memory resources.
pub fn initResources() Error!void {
    const allocator = getIoAllocator();

    // DRAM
    for (pmap.drams, 0..) |dram, i| {
        const res = try allocator.reserve(
            "System RAM",
            dram.start,
            dram.size(),
            null,
        );

        if (i == 0) {
            _ = try allocator.reserve(
                "Kernel Image",
                pmap.kernel,
                kernelSize(),
                res,
            );
        }
    }
}

/// Remap the I/O memory regions of the board.
pub fn remapBoard() Error!void {
    try board.remap(getIoAllocator());
}

/// Get the page allocator.
pub fn getPageAllocator() PageAllocator {
    return buddy_allocator.interface();
}

/// Get the general-purpose allocator.
pub fn getGeneralAllocator() Allocator {
    return bin_allocator.interface();
}

/// Get the VM allocator.
pub fn getIoAllocator() IoAllocator {
    return phys_allocator.interface();
}

/// Get the set of memory allocators.
pub fn getAllocators() MemoryManager {
    return MemoryManager{
        .general = getGeneralAllocator(),
        .io = getIoAllocator(),
        .page = getPageAllocator(),
    };
}

/// Get the kernel page table.
///
/// The returned table pair does not contain the user page table.
pub fn getKernelPageTable() arch.mmu.PageTablePair {
    return .{
        .l0 = null,
        .l1 = init_pt.l1,
    };
}

/// Get the initial task's page table.
pub fn getInitPageTablePair() arch.mmu.PageTablePair {
    return init_pt;
}

/// End virtual address of kernel image.
extern const __end: *void;

/// Get the size in bytes of the kernel image.
fn kernelSize() usize {
    return @intFromPtr(&__end) - urd.mem.vmap.kernel.start;
}

// =============================================================
// Debug
// =============================================================

/// Print all resources to the given logger for debug.
pub fn debugPrintResources(logger: anytype) void {
    phys_allocator.debugPrintResources(logger);
}

// =============================================================
// Tests
// =============================================================

test {
    _ = BinAllocator;
    _ = BuddyAllocator;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.mem);
const Allocator = std.mem.Allocator;
const arch = @import("arch").impl;
const board = @import("board").impl;
const common = @import("common");
const rtt = common.rtt;
const units = common.units;
const util = common.util;
const MemoryManager = common.mem.MemoryManager;
const PageAllocator = common.mem.PageAllocator;
const IoAllocator = common.mem.IoAllocator;
const Range = common.Range;
const urd = @import("urthr");
const pmap = board.memmap;
const BinAllocator = @import("mem/BinAllocator.zig");
const BuddyAllocator = @import("mem/BuddyAllocator.zig");
const PhysAllocator = @import("mem/PhysAllocator.zig");

const size_4kib = common.mem.size_4kib;
const size_2mib = common.mem.size_2mib;
const size_1gib = common.mem.size_1gib;
