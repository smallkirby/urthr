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
    // We assume loader < loader reserved < kernel,
    // and the loader region is larger than 1 MiB.
    const boot_worksize = 1 * units.mib;
    urd.comptimeAssert(
        board.memmap.loader + boot_worksize <= board.memmap.loader_reserved.start,
        \\Region reserved for boot-time allocator overwraps the bootloader region.
        \\  Loader Start + Work Buffer = 0x{X:0>8}
        \\  Loader Reserved Start      = 0x{X:0>8}
    ,
        .{ board.memmap.loader + boot_worksize, board.memmap.loader_reserved.start },
    );
    const pa_reserved = common.Range{
        .start = board.memmap.loader,
        .end = board.memmap.loader + boot_worksize,
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

    // Initialize networking stack.
    log.debug("Initializing networking stack.", .{});
    try urd.net.init();

    // Initialize peripherals.
    log.info("Initializing peripherals.", .{});
    try board.initPeripherals(urd.mem.getAllocators());

    log.debug("Memory Map:", .{});
    urd.mem.debugPrintResources(log.debug);

    // Initialize RNG.
    log.info("Initializing RNG.", .{});
    urd.rng.init();

    // Setup IRQ.
    log.debug("Setting up IRQ.", .{});
    urd.exception.initLocal();

    // Initialize scheduler.
    log.info("Initializing scheduler.", .{});
    try urd.sched.init();

    // Initialize filesystem.
    log.info("Initializing filesystem.", .{});
    try urd.fs.init(urd.mem.getGeneralAllocator());

    if (board.getBlockDevice()) |dev| {
        // List partitions on the block device.
        const partitions = try common.block.partitions.listPartitions(dev, urd.mem.getGeneralAllocator());
        defer urd.mem.getGeneralAllocator().free(partitions);
        log.info("Found {d} partitions:", .{partitions.len});

        for (partitions, 0..) |*part, i| {
            const bytes_per_sector = 512;
            log.info("  Partition#{d}: LBA {d}, Size {d} sectors ({d} MiB)", .{
                i,
                part.lba,
                part.nsecs,
                (part.nsecs * bytes_per_sector) / units.mib,
            });
        }

        // Mount the boot filesystem.
        if (try createBootFs(dev)) |fs| {
            try urd.fs.mount(urd.sched.getCurrent().fs.root, fs, urd.mem.getGeneralAllocator());
        } else {
            log.warn("No boot filesystem found.", .{});
        }
    } else {
        log.warn("No block device found", .{});
    }

    // Initialize time subsystem.
    log.info("Initializing time subsystem.", .{});
    urd.time.init();

    // Spawn the initial kernel thread.
    log.info("Spawning initial task.", .{});
    _ = try urd.sched.spawn("init", initialTask, .{});

    // Start preemptive scheduling timer.
    try urd.sched.start();

    // Start the scheduler.
    urd.sched.reschedule();

    // If the idle watchdog is enabled, monitor the idle thread's execution time.
    if (options.idle_watchdog != 0) {
        while (true) {
            urd.sched.reschedule();
            arch.halt();
        }
    }
}

/// Initial kernel thread task.
fn initialTask() !void {
    log.info("Initial task started.", .{});

    // Start networking subsystem.
    log.info("Starting networking subsystem.", .{});
    try urd.net.run();
}

// =============================================================
// Utilities
// =============================================================

fn createBootFs(dev: common.block.Device) urd.fs.Error!?urd.fs.FileSystem {
    const allocator = urd.mem.getGeneralAllocator();
    const partitions = try common.block.partitions.listPartitions(dev, allocator);
    defer allocator.free(partitions);

    // Find a partition with a specific label.
    for (partitions) |*p| {
        const part = try allocator.create(common.block.partitions.Partition);
        errdefer allocator.destroy(part);
        part.* = p.*;

        const fat32 = urd.fs.Fat32.init(part.interface(), allocator) catch {
            continue;
        };
        const fs = fat32.filesystem();

        const label = fs.getLabel(allocator) catch {
            allocator.destroy(fat32);
            continue;
        };
        defer allocator.free(label);

        if (std.mem.eql(u8, label, "bootfs")) {
            return fs;
        }

        allocator.destroy(fat32);
        allocator.destroy(part);
    }

    // Use the first partition.
    if (partitions.len > 0) {
        const part = try allocator.create(common.block.partitions.Partition);
        errdefer allocator.destroy(part);
        part.* = partitions[0];

        const fat32 = try urd.fs.Fat32.init(part.interface(), allocator);
        return fat32.filesystem();
    }

    return null;
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
const options = @import("options");

// Force evaluate symbols exported but not referenced in Zig.
comptime {
    _ = arch;
}
