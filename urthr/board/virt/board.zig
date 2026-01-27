pub const memmap = @import("memmap.zig");

/// Virtio block device instance.
var virtio_blk_dev: ?dd.VirtioBlk = null;

/// Early board initialization.
///
/// Sets up essential peripherals like UART.
pub fn boot() void {
    // Setup PL011 UART.
    dd.pl011.setBase(memmap.pl011.start);
    dd.pl011.init(48_000_000, 921_600); // 48 MHz, 921600 bps
}

/// Map new I/O memory regions.
pub fn remap(allocator: IoAllocator) IoAllocator.Error!void {
    // PL011 UART.
    dd.pl011.setBase(try allocator.reserveAndRemap(
        "PL011",
        memmap.pl011.start,
        memmap.pl011.size(),
        null,
    ));
}

/// De-initialize loader resources.
pub fn deinitLoader() void {}

/// Initialize peripherals.
pub fn initPeripherals(mm: MemoryManager) mem.Error!void {
    const virtio_size = dd.virtio.mmio_space_size;

    // Scan for virtio-blk device.
    const virtio_base = try mm.io.reserveAndRemap(
        "virtio",
        memmap.virtio.start,
        util.roundup(memmap.virtio.size(), common.mem.size_4kib),
        null,
    );

    for (0..(memmap.virtio.size() / virtio_size)) |i| {
        const base = virtio_base + i * virtio_size;

        // Try to initialize as virtio-blk.
        virtio_blk_dev = dd.VirtioBlk.init(base, mm.page, mm.general) catch {
            continue;
        };

        log.info("Found virtio-blk device#{d}", .{i});
        break;
    }
}

/// Get the block device interface.
pub fn getBlockDevice() ?common.block.Device {
    return if (virtio_blk_dev) |*dev|
        dev.interface()
    else
        null;
}

/// Get console instance.
///
/// This is a zero cost operation with no runtime overhead.
pub fn getConsole() Console {
    return .{
        .vtable = .{
            .putc = console.putc,
            .flush = console.flush,
        },
        .ctx = &.{},
    };
}

/// Get the regions that must be identity-mapped during boot.
pub inline fn getTempMaps() []const common.Range {
    return &[_]common.Range{
        memmap.pl011,
    };
}

/// Trigger a system cold reset.
///
/// This function returns before the reset actually happens.
pub fn reset(status: u8) void {
    const arg: extern struct {
        v: u64,
        status: u64,
    } = .{
        .v = 0x20026,
        .status = status,
    };

    asm volatile (
        \\mov x0, #0x18
        \\mov x1, %[arg]
        \\hlt #0xF000
        :
        : [arg] "r" (&arg),
    );

    while (true) {
        arch.halt();
    }
}

/// Wrapper functions for console API.
const console = struct {
    fn putc(_: *anyopaque, c: u8) void {
        return dd.pl011.putc(c);
    }

    fn flush(_: *anyopaque) void {
        return dd.pl011.flush();
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.virt);
const arch = @import("arch").impl;
const common = @import("common");
const mem = common.mem;
const util = common.util;
const Console = common.Console;
const MemoryManager = common.mem.MemoryManager;
const IoAllocator = mem.IoAllocator;
const PageAllocator = mem.PageAllocator;
const dd = @import("dd");
