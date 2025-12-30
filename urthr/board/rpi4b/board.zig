pub const memmap = @import("memmap.zig");

/// Early board initialization.
///
/// Sets up essential peripherals like GPIO and UART.
pub fn boot() void {
    // Setup GPIO.
    dd.gpio.setBase(map.gpio.start);

    // Setup PL011 UART.
    dd.pl011.setBase(map.pl011.start);
    dd.gpio.selectAltFn(14, .alt0); // TXD0
    dd.gpio.selectAltFn(15, .alt0); // RXD0
    dd.pl011.init(48_000_000, 921_600); // 48 MHz, 921600 bps

    // Setup PM.
    rdd.pm.setBase(map.pm.start);
}

/// Map new I/O memory regions.
pub fn remap(allocator: IoAllocator) IoAllocator.Error!void {
    // GPIO
    dd.gpio.setBase(try allocator.reserveAndRemap(
        "GPIO",
        map.gpio.start,
        map.gpio.size(),
    ));

    // PL011 UART.
    dd.pl011.setBase(try allocator.reserveAndRemap(
        "PL011",
        map.pl011.start,
        map.pl011.size(),
    ));

    // PM.
    rdd.pm.setBase(try allocator.reserveAndRemap(
        "PM",
        memmap.pm.start,
        memmap.pm.size(),
    ));
}

/// De-initialize loader resources.
pub fn deinitLoader() void {}

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

/// Trigger a system cold reset.
///
/// This function returns before the reset actually happens.
pub fn reset() void {
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
const arch = @import("arch");
const common = @import("common");
const Console = common.Console;
const IoAllocator = common.IoAllocator;
const dd = @import("dd");
const map = @import("memmap.zig");
const rdd = @import("dd.zig");
