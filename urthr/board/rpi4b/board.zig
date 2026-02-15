pub const memmap = @import("memmap.zig");

/// Function signature of exception handler.
///
/// Returns null if the exception cannot be handled.
pub const ExceptionHandler = *const fn (u64) ?void;

/// Exception handler called when an IRQ occurs.
var exception_handler: ?ExceptionHandler = null;

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
pub fn initPeripherals(mm: MemoryManager) mem.Error!void {
    // Interrupt controller.
    {
        arch.gicv2.setBase(try mm.io.reserveAndRemap(
            "GIC",
            map.gic.start,
            map.gic.size(),
            null,
        ));
        arch.gicv2.initGlobal();
    }

    // SDHC
    {
        const base = try mm.io.reserveAndRemap(
            "SDHC",
            memmap.sdhost.start,
            memmap.sdhost.size(),
            null,
        );
        dd.sdhc.setBase(base);
        dd.sdhc.init(
            50_000_000, // 50 MHz
            mm.page,
        );
    }
}

/// De-initialize loader resources.
pub fn deinitLoader() void {}

/// Initialize GICC for the calling AP.
pub fn initIrqLocal() void {
    // Set exception handler.
    arch.intr.setHandler(handleIrq);

    // Initialize CPU interface.
    arch.gicv2.initLocal();
}

/// Enable an interrupt by ID.
pub fn enableIrq(id: usize) void {
    arch.gicv2.enableIrq(id);
}

/// Set the exception handler for IRQs.
pub fn setIrqHandler(f: ExceptionHandler) void {
    exception_handler = f;
}

/// IRQ handler function.
fn handleIrq() ?void {
    const iar = arch.gicv2.readIar();
    const intid = iar.interrupt_id;

    if (exception_handler) |handler| {
        if (handler(intid)) |_| {
            arch.gicv2.eoi(iar);

            // Reschedule if needed.
            if (urd.sched.getCurrent().need_resched) {
                urd.sched.reschedule();
            }

            return;
        } else {
            // Handler for this interrupt not registered.
            return null;
        }
    } else {
        // Root handler registered.
        return null;
    }
}

/// Get the block device interface.
pub fn getBlockDevice() ?common.block.Device {
    return dd.sdhc.interface();
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
const arch = @import("arch").impl;
const common = @import("common");
const mem = common.mem;
const options = common.options;
const Console = common.Console;
const IoAllocator = common.mem.IoAllocator;
const MemoryManager = common.mem.MemoryManager;
const urd = @import("urthr");
const dd = @import("dd");
const map = @import("memmap.zig");
const rdd = @import("dd.zig");
