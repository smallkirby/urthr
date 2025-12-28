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
const dd = @import("dd");
const map = @import("memmap.zig");
