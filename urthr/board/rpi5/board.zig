pub const memmap = @import("memmap.zig");

/// Function signature of exception handler.
///
/// Returns null if the exception cannot be handled.
pub const ExceptionHandler = *const fn (u64) ?void;

/// Exception handler called when an IRQ occurs.
var exception_handler: ?ExceptionHandler = null;

/// GEM controller instance.
var gem: dd.net.Gem = undefined;

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
pub fn initPeripherals(mm: MemoryManager) mem.Error!void {
    // Interrupt controller.
    {
        arch.gicv2.setBase(try mm.io.reserveAndRemap(
            "GIC",
            memmap.gic.start,
            memmap.gic.size(),
            null,
        ));
        arch.gicv2.initGlobal();
    }

    // PCIe.
    log.info("Initializing PCIe controller.", .{});
    {
        const pci = try mm.io.reserveAndRemap(
            "PCIe",
            memmap.pci.start,
            memmap.pci.size(),
            null,
        );
        rdd.pcie.setBase(pci);
        rdd.pcie.init(mm.page);
    }

    // RP1.
    log.info("Initializing RP1.", .{});
    {
        try rdd.rp1.init(mm.io);
    }

    // GPIO.
    log.info("Initializing GPIO.", .{});
    {
        rdd.gpio.setBase(
            rdd.rp1.getIoBankBase(),
            rdd.rp1.getRioBase(),
            rdd.rp1.getPadsBase(),
        );
    }

    // Clock.
    log.info("Initializing Clocks.", .{});
    {
        rdd.clk.setBase(rdd.rp1.getClocksMain());
        rdd.clk.init();
    }

    // SDHC.
    log.info("Initializing SDHC.", .{});
    {
        const sdbase = try mm.io.reserveAndRemap(
            "SDHC",
            memmap.sd.start,
            memmap.sd.size(),
            null,
        );

        dd.sdhc.setBase(sdbase);
        dd.sdhc.init(
            50_000_000, // 50 MHz PLL base clock
            mm.page,
        );
    }

    // Ethernet.
    log.info("Initializing Ethernet.", .{});
    {
        rdd.ether.setBase(rdd.rp1.getEthrBase(), rdd.rp1.getEthrCfgBase());

        // Initialize Ethernet MAC.
        rdd.ether.resetPhy();
        gem = dd.net.Gem.new(
            rdd.rp1.getEthrBase(),
            rdd.pcie.getDmaAllocator(),
        );
        gem.init();

        // Register interrupt handler.
        const gem_intid = rdd.rp1.getIrqNumber(.eth);
        urd.exception.setHandler(gem_intid, handleGemIrq) catch |err| {
            log.err("Failed to register GEM IRQ handler: {}", .{err});
        };
        arch.gicv2.setTrigger(gem_intid, .edge);
        arch.gicv2.enableIrq(gem_intid);
    }
}

/// Initialize GICC for the calling AP.
pub fn initIrqLocal() void {
    // Set exception handler.
    arch.intr.setHandler(handleIrq);

    // Initialize CPU interface.
    arch.gicv2.initLocal();
}

/// Set the exception handler for IRQs.
pub fn setIrqHandler(f: ExceptionHandler) void {
    exception_handler = f;
}

/// IRQ handler function.
fn handleIrq() ?void {
    const iar = arch.gicv2.readIar();
    const intid = iar.interrupt_id;

    log.debug("IRQ#{d} received", .{intid});

    if (exception_handler) |handler| {
        if (handler(intid)) |_| {
            // Handled successfully.
            arch.gicv2.eoi(iar);
            return;
        } else {
            // Handler for this interrupt not registered.
            arch.gicv2.eoi(iar);
            return null;
        }
    } else {
        // No root handler registered.
        arch.gicv2.eoi(iar);
        return null;
    }
}

/// Handle GEM interrupt.
fn handleGemIrq() void {
    gem.handleInterrupt();

    rdd.rp1.ackMsix(.eth);
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
const arch = @import("arch").impl;
const common = @import("common");
const mem = common.mem;
const Console = common.Console;
const MemoryManager = mem.MemoryManager;
const IoAllocator = mem.IoAllocator;
const dd = @import("dd");
const rdd = @import("dd.zig");
const urd = @import("urthr");
