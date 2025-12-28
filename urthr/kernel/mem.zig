pub const Error = arch.mmu.Error;

/// Buddy allocator instance.
var buddy_allocator: BuddyAllocator = undefined;

/// Initialize memory management.
///
/// This kernel creates new MMU mapping.
pub fn init() Error!void {
    const allocator = urd.boot.getAllocator().interface();

    // Arch-specific MMU preparation.
    try arch.mmu.init(allocator);

    // Kernel mapping: 1GiB granule, RWX, normal.
    log.debug("Mapping kernel.", .{});
    try arch.mmu.map1gb(
        pmap.kernel,
        vmap.kernel.start + pmap.kernel,
        util.roundup(kernelSize(), units.gib),
        .kernel_rwx,
        .normal,
        allocator,
    );

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
        const peri = pmap.pl011;

        try arch.mmu.map4kb(
            peri.start,
            peri.start,
            peri.size(),
            .kernel_rw,
            .device,
            allocator,
        );
    }

    // Switch to the new page table.
    log.debug("Switching to new page table.", .{});
    arch.mmu.enable(allocator);
}

/// Initialize the page allocator.
pub fn initPageAllocator() void {
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
}

/// Get the page allocator.
pub fn getPageAllocator() PageAllocator {
    return buddy_allocator.interface();
}

/// End virtual address of kernel image.
extern const __end: *void;

/// Get the size in bytes of the kernel image.
fn kernelSize() usize {
    return @intFromPtr(__end) - urd.mem.vmap.kernel.start;
}

// =============================================================
// Tests
// =============================================================

test {
    _ = BuddyAllocator;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.mem);
const arch = @import("arch").impl;
const board = @import("board").impl;
const common = @import("common");
const units = common.units;
const util = common.util;
const PageAllocator = common.PageAllocator;
const Range = common.Range;
const urd = @import("urthr");
const pmap = board.memmap;
const vmap = @import("mem/vmemmap.zig");
const BuddyAllocator = @import("mem/BuddyAllocator.zig");
