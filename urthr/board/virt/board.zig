pub const memmap = @import("memmap.zig");

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
    ));
}

/// De-initialize loader resources.
pub fn deinitLoader() void {}

/// Initialize peripherals.
pub fn initPeripherals(allocator: IoAllocator) IoAllocator.Error!void {
    _ = allocator;
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
const arch = @import("arch").impl;
const common = @import("common");
const Console = common.Console;
const IoAllocator = common.IoAllocator;
const dd = @import("dd");
