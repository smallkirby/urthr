pub const memmap = @import("memmap.zig");

/// Early board initialization.
///
/// Sets up essential peripherals like UART.
pub fn boot() void {
    // Setup PL011 UART.
    dd.pl011.setBase(memmap.pl011.start);
    dd.pl011.init(44_236_800, 921_600); // 44.237 MHz, 921600 bps

    // Setup PM.
    rdd.pm.setBase(memmap.pm.start);
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

    // PM.
    rdd.pm.setBase(try allocator.reserveAndRemap(
        "PM",
        memmap.pm.start,
        memmap.pm.size(),
        null,
    ));
}

/// De-initialize loader resources.
pub fn deinitLoader() void {}

/// Initialize peripherals.
pub fn initPeripherals(allocator: IoAllocator) IoAllocator.Error!void {
    // PCIe.
    log.info("Initializing PCIe controller.", .{});
    {
        const pci = try allocator.ioremap(
            memmap.pci.start,
            memmap.pci.size(),
        );
        rdd.pcie.setBase(pci);
        rdd.pcie.init();
    }

    // RP1.
    log.info("Initializing RP1.", .{});
    {
        try rdd.rp1.init(allocator);
    }
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
        memmap.pm,
    };
}

/// Trigger a system cold reset.
///
/// This function returns before the reset actually happens.
///
/// Argument is ignored.
pub fn reset(_: u8) void {
    rdd.pm.reset();
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
const log = std.log.scoped(.rpi5);
const arch = @import("arch");
const common = @import("common");
const Console = common.Console;
const IoAllocator = common.IoAllocator;
const dd = @import("dd");
const rdd = @import("dd.zig");
