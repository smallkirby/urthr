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
        null,
    ));

    // PL011 UART.
    dd.pl011.setBase(try allocator.reserveAndRemap(
        "PL011",
        map.pl011.start,
        map.pl011.size(),
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

/// Initialize peripherals.
pub fn initPeripherals(allocator: IoAllocator) IoAllocator.Error!void {
    // SDHC
    {
        const base = try allocator.reserveAndRemap(
            "SDHC",
            memmap.sdhost.start,
            memmap.sdhost.size(),
            null,
        );
        dd.sdhc.setBase(base);
        dd.sdhc.init(50_000_000); // 50 MHz
    }
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
pub fn reset(status: u8) void {
    if (options.enable_rtt) {
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
    } else {
        rdd.pm.reset();
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
const arch = @import("arch");
const common = @import("common");
const Console = common.Console;
const IoAllocator = common.IoAllocator;
const options = common.options;
const dd = @import("dd");
const map = @import("memmap.zig");
const rdd = @import("dd.zig");
