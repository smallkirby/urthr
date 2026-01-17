pub const Error = common.mem.Error;

pub const vallocator = @import("mem/vallocator.zig");

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

/// Initialize memory management.
///
/// This kernel creates new MMU mapping.
pub fn init() Error!void {
    const allocator = urd.boot.getAllocator().interface();

    // Arch-specific MMU preparation.
    try arch.mmu.init(allocator);

    // Kernel mapping: 2MiB granule, RWX, normal.
    log.debug("Mapping kernel.", .{});
    {
        rtt.expectEqual(0, pmap.kernel % size_2mib);
        rtt.expectEqual(0, vmap.kernel.start % size_2mib);
        try arch.mmu.map2mb(
            pmap.kernel,
            vmap.kernel.start,
            util.roundup(kernelSize(), 2 * units.mib),
            .kernel_rwx,
            .normal,
            allocator,
        );
    }

    // Linear mapping: 1GiB granule, RW, normal.
    log.debug("Mapping linear memory.", .{});
    {
        for (pmap.drams) |dram| {
            try arch.mmu.map1gb(
                dram.start,
                vmap.linear.start + dram.start,
                dram.size(),
                .kernel_rw,
                .normal,
                allocator,
            );
        }
    }

    // Temporary device identity mapping: 4KiB granule, RW, device.
    log.debug("Mapping device memory.", .{});
    {
        for (board.getTempMaps()) |range| {
            try arch.mmu.map4kb(
                range.start,
                range.start,
                range.size(),
                .kernel_rw,
                .device,
                allocator,
            );
        }
    }

    // Switch to the new page table.
    log.debug("Switching to new page table.", .{});
    arch.mmu.enable(allocator);
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

    // Bin allocator.
    bin_allocator.init(getPageAllocator());

    // I/O allocator.
    phys_allocator.init();
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
const PageAllocator = common.PageAllocator;
const IoAllocator = common.IoAllocator;
const Range = common.Range;
const urd = @import("urthr");
const pmap = board.memmap;
const vmap = @import("mem/vmemmap.zig");
const BinAllocator = @import("mem/BinAllocator.zig");
const BuddyAllocator = @import("mem/BuddyAllocator.zig");
const PhysAllocator = @import("mem/PhysAllocator.zig");

const size_4kib = common.mem.size_4kib;
const size_2mib = common.mem.size_2mib;
const size_1gib = common.mem.size_1gib;
