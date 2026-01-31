/// Override the standard options.
pub const std_options = std.Options{
    // Logging
    .logFn = urd.klog.log,
    .log_level = urd.klog.log_level,
};

/// Override the standard panic function.
pub const panic = @import("kernel/panic.zig").panic_fn;

/// Zig entry point for Urthr kernel.
export fn kmain() callconv(.c) noreturn {
    // Early board initialization.
    board.boot();

    // Init kernel logger.
    urd.klog.set(board.getConsole());

    // Initialize exception handling.
    urd.exception.boot();

    // Print a boot message.
    log.info("", .{});
    log.info("Booting Urthr...", .{});

    // Init early page allocator.
    const pa_reserved = common.Range{
        .start = board.memmap.loader_reserved.end,
        .end = board.memmap.loader_reserved.end + 1 * units.mib,
    };
    urd.boot.initAllocator(pa_reserved.start, pa_reserved.size());
    log.info("Early allocator reserved 0x{X:0>8} - 0x{X:0>8}", .{ pa_reserved.start, pa_reserved.end });

    zmain() catch |err| {
        log.err("ERROR: {}", .{err});
    };

    // Halt.
    log.err("Reached unreachable EOL.", .{});
    urd.eol(0);
}

/// Zig calling convention entry.
fn zmain() !void {
    // Initialize mappings.
    log.info("Initializing MMU.", .{});
    try urd.mem.init();

    // Deinit loader.
    board.deinitLoader();

    // Initialize page allocator.
    log.info("Initializing allocators.", .{});
    urd.mem.initAllocators();

    // Initialize memory resources.
    log.info("Initializing memory resources.", .{});
    try urd.mem.initResources();

    // Remap board I/O memory.
    log.info("Remapping board I/O memory.", .{});
    try urd.mem.remapBoard();

    // Initialize peripherals.
    log.info("Initializing peripherals.", .{});
    try board.initPeripherals(urd.mem.getAllocators());

    log.debug("Memory Map:", .{});
    urd.mem.debugPrintResources(log.debug);

    // Setup IRQ.
    log.debug("Setting up IRQ.", .{});
    urd.exception.initLocal();

    // List partitions on the block device.
    if (board.getBlockDevice()) |dev| {
        const partitions = try common.block.partitions.listPartitions(dev, urd.mem.getGeneralAllocator());
        log.info("Found {d} partitions:", .{partitions.len});

        for (partitions, 0..) |part, i| {
            const bytes_per_sector = 512;
            log.info("  Partition#{d}: LBA {d}, Size {d} sectors ({d} MiB)", .{
                i,
                part.lba,
                part.nsecs,
                (part.nsecs * bytes_per_sector) / units.mib,
            });
        }
    } else {
        log.warn("No block device found", .{});
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.main);
const arch = @import("arch").impl;
const board = @import("board").impl;
const common = @import("common");
const units = common.units;
const urd = @import("urthr");

// Force evaluate symbols exported but not referenced in Zig.
comptime {
    _ = arch;
}
