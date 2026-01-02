pub const Error = common.mem.Error;

pub const resource = @import("mem/resource.zig");

/// Size in bytes of 4KiB.
pub const size_4kib = 4 * units.kib;
/// Size in bytes of 2MiB.
pub const size_2mib = 2 * units.mib;
/// Size in bytes of 1GiB.
pub const size_1gib = 1 * units.gib;

/// Virtual address type.
pub const Virt = usize;
/// Physical address type.
pub const Phys = usize;

/// Buddy allocator instance.
var buddy_allocator: BuddyAllocator = undefined;
/// Bin allocator instance.
var bin_allocator: BinAllocator = undefined;
/// VM allocator instance.
var vm_allocator: VmAllocator = undefined;

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

    // VM allocator.
    vm_allocator.init(vmap.vmem.start, vmap.vmem.end);
}

/// Initialize memory resources.
pub fn initResources() Error!void {
    const allocator = getGeneralAllocator();

    // DRAM
    for (pmap.drams, 0..) |dram, i| {
        const res = try resource.requestResource(
            "System RAM",
            dram.start,
            dram.size(),
            allocator,
        );

        if (i == 0) {
            _ = try res.appendChild(
                "Kernel Image",
                pmap.kernel,
                kernelSize(),
                allocator,
            );
        }
    }
}

/// Remap the I/O memory regions of the board.
pub fn remapBoard() Error!void {
    try board.remap(vm_allocator.interface());
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
pub fn getVmAllocator() IoAllocator {
    return vm_allocator.interface();
}

/// End virtual address of kernel image.
extern const __end: *void;

/// Get the size in bytes of the kernel image.
fn kernelSize() usize {
    return @intFromPtr(&__end) - urd.mem.vmap.kernel.start;
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
const units = common.units;
const util = common.util;
const PageAllocator = common.PageAllocator;
const IoAllocator = common.IoAllocator;
const Range = common.Range;
const urd = @import("urthr");
const rtt = urd.rtt;
const pmap = board.memmap;
const vmap = @import("mem/vmemmap.zig");
const BinAllocator = @import("mem/BinAllocator.zig");
const BuddyAllocator = @import("mem/BuddyAllocator.zig");
const VmAllocator = @import("mem/VmAllocator.zig");
