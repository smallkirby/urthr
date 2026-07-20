pub const Error = common.mem.Error;

/// Allocator implementing `std.mem.Allocator` interface.
pub const bin = bin_impl.interface;
/// Allocator implementing `common.mem.DmaAllocator` interface.
pub const dma = @import("mem/dma.zig");
/// Allocator implementing `common.mem.PageAllocator` interface.
pub const page = buddy_impl.interface;
/// Allocator implementing `common.mem.IoAllocator` interface.
pub const phys = phys_impl.interface;
/// Virtual memory allocator.
pub const virt = @import("mem/virt.zig");
pub const vmap = @import("mem/vmemmap.zig");

/// Virtual address type.
pub const Virt = usize;
/// Physical address type.
pub const Phys = usize;

pub const page_size = common.mem.size_4kib;
pub const size_4kib = common.mem.size_4kib;
pub const size_2mib = common.mem.size_2mib;
pub const size_1gib = common.mem.size_1gib;

/// Init task's page table.
var init_as: arch.mmu.AddressSpace = .{};

/// Initialize memory management.
///
/// This kernel creates new MMU mapping.
pub fn init() Error!void {
    const allocator = boot.interface();

    // Allocate kernel root address space and init task's user address space.
    init_as = try arch.mmu.createAddressSpace(allocator);

    // Kernel mapping: 2MiB granule, RWX, normal.
    log.debug("Mapping kernel.", .{});
    {
        const kphys = board.getKernelPaddr();
        rtt.expectEqual(0, kphys % size_2mib);
        rtt.expectEqual(0, vmap.kernel.start % size_2mib);
        try arch.mmu.map2mb(init_as, .{
            .pa = kphys,
            .va = vmap.kernel.start,
            .size = util.roundup(kernelSize(), 2 * units.mib),
            .perm = .kernel_rwx,
            .attr = .normal,
        }, .{}, allocator);
    }

    // Linear mapping: 1GiB granule, RW, normal.
    log.debug("Mapping linear memory.", .{});
    {
        for (board.getDramRegion()) |dram| {
            try arch.mmu.map1gb(init_as, .{
                .pa = dram.start,
                .va = vmap.linear.start + dram.start,
                .size = dram.size(),
                .perm = .kernel_rw,
                .attr = .normal,
            }, .{ .exact = false }, allocator);
        }
    }

    // Temporary I/O identity mapping: 4KiB granule, RW, device.
    log.debug("Mapping device temp memory.", .{});
    {
        for (board.getIoTempMaps()) |range| {
            try arch.mmu.map4kb(init_as, .{
                .pa = range.start,
                .va = range.start,
                .size = range.size(),
                .perm = .kernel_rw,
                .attr = .device,
            }, .{}, allocator);
        }
    }

    // Temporary normal-memory identity mapping: 4KiB granule, RW, normal.
    log.debug("Mapping normal temp memory.", .{});
    {
        for (board.getNormalTempMaps()) |range| {
            try arch.mmu.map4kb(init_as, .{
                .pa = range.start,
                .va = range.start,
                .size = range.size(),
                .perm = .kernel_rw,
                .attr = .normal,
            }, .{}, allocator);
        }
    }

    // Switch to the new address space.
    log.debug("Switching to new page table.", .{});
    arch.mmu.enable(init_as, allocator);
}

/// Initialize allocators.
pub fn initAllocators() Error!void {
    // Page allocator.
    const kphys = board.getKernelPaddr();
    const avails = board.getDramRegion();
    var reserveds = [_]Range{
        // Kernel image
        .{
            .start = kphys,
            .end = kphys + kernelSize(),
        },
        // Early allocator region
        boot.getUsedRegion(),
    };
    buddy_impl.init(avails, &reserveds, log.debug);

    // Update page table virtual address.
    arch.mmu.relocate(&init_as, page);

    // Bin allocator.
    bin_impl.init(page);

    // I/O allocator.
    phys_impl.init();

    // Virtual memory allocator.
    try virt.init();

    // Now then, boot allocator is no longer needed.
}

/// Initialize memory resources.
pub fn initResources() Error!void {
    const allocator = phys;
    const kphys = board.getKernelPaddr();

    // DRAM
    for (board.getDramRegion(), 0..) |dram, i| {
        const res = try allocator.reserve(
            "System RAM",
            dram.start,
            dram.size(),
            null,
        );

        if (i == 0) {
            _ = try allocator.reserve(
                "Kernel Image",
                kphys,
                kernelSize(),
                res,
            );
        }
    }
}

/// Remap the I/O and normal temp regions of the board.
pub fn remapBoard() Error!void {
    try board.remapIo(phys_impl.interface);
    try board.remapNormal(boot.interface(), page);
}

/// Get the kernel address space.
///
/// The returned address space does not contain the user mapping.
pub fn getKernelPageTable() arch.mmu.AddressSpace {
    return init_as.kernelOnly();
}

/// Get the initial task's address space.
pub fn getInitAddressSpace() arch.mmu.AddressSpace {
    return init_as;
}

/// Check if the given address is a user-space address.
pub fn isUserAddress(va: usize) bool {
    return vmap.user.start <= va and va < vmap.user.end;
}

/// Statistics of an allocator.
pub const Stats = struct {
    /// Total size in bytes managed by the allocator.
    total_bytes: usize,
    /// Free size in bytes.
    free_bytes: usize,
};

/// Get memory statistics.
pub fn getStats() Stats {
    return buddy_impl.getStats();
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
    phys_impl.debugPrintResources(logger);
}

// =============================================================
// Boot
// =============================================================

/// APIs for early boot stage.
pub const boot = struct {
    const impl = @import("mem/boot.zig");

    /// Initialize the early page allocator.
    ///
    /// The buffer is reserved for early boot use only.
    ///
    /// This region should not overlap with the region reserved by Wyrd.
    pub fn init(start: usize, size: usize) void {
        const ptr: [*]u8 = @ptrFromInt(start);
        impl.init(ptr[0..size]);
    }

    /// Get the region used by the early page allocator.
    pub fn getUsedRegion() Range {
        return impl.getUsedRegion();
    }

    /// Get `PageAllocator` interface.
    pub fn interface() PageAllocator {
        return impl.interface;
    }
};

// =============================================================
// Tests
// =============================================================

test {
    _ = bin_impl;
    _ = buddy_impl;
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
const PageAllocator = common.mem.PageAllocator;
const IoAllocator = common.mem.IoAllocator;
const Range = common.Range;
const urd = @import("urthr");
const bin_impl = @import("mem/bin.zig");
const buddy_impl = @import("mem/page.zig");
const phys_impl = @import("mem/phys.zig");
