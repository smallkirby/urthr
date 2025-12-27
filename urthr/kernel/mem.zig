pub const Error = arch.mmu.Error;

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
        vmap.kernel.start,
        vmap.kernel.size(),
        .kernel_rwx,
        .normal,
        allocator,
    );

    // Linear mapping: 1GiB granule, RW, normal.
    log.debug("Mapping linear memory.", .{});
    {
        var cur = vmap.linear.start;

        for (pmap.drams) |dram| {
            try arch.mmu.map1gb(
                dram.start,
                cur,
                dram.size(),
                .kernel_rw,
                .normal,
                allocator,
            );

            cur += dram.size();
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
    arch.mmu.enable(allocator);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.mem);
const arch = @import("arch").impl;
const board = @import("board").impl;
const common = @import("common");
const PageAllocator = common.PageAllocator;
const urd = @import("urthr");
const pmap = board.memmap;
const vmap = @import("mem/vmemmap.zig");
