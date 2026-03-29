pub const memmap = @import("memmap.zig");

/// Function signature of exception handler.
///
/// Returns null if the exception cannot be handled.
pub const ExceptionHandler = *const fn (u64) ?void;

/// Exception handler called when an IRQ occurs.
var exception_handler: ?ExceptionHandler = null;

/// MAC address of GEM controller.
const gem_mac = net.ether.MacAddr.encode("B8:27:EB:00:00:00");

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
pub fn initPeripherals(mm: MemoryManager) (mem.Error || net.Error)!void {
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

        // Initialize Ethernet MAC PHY.
        rdd.ether.resetPhy();

        // Initialize GEM network device to register to the network stack.
        const gemdev = try dd.net.Gem.new(
            rdd.rp1.getEthrBase(),
            gem_mac,
            mm.general,
            rdd.pcie.getDmaAllocator(),
        );
        urd.net.registerDevice(gemdev);

        // Register interrupt handler.
        const intid = rdd.rp1.getIrqNumber(.eth);
        arch.gicv2.setTrigger(intid, .edge);
        arch.gicv2.enableIrq(intid);
        try net.registerIrq(gemdev, intid);

        // TODO: should we create an interface here?
        const iface = try urd.net.ip.Interface.create(
            net.ip.IpAddr.comptimeParse("0.0.0.0"),
            net.ip.IpAddr.comptimeParse("255.255.255.0"),
            mm.general,
        );
        try gemdev.appendInterface(iface);
    }
}

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

            rdd.rp1.ackMsix(.eth); // TODO: should check if this is actually an Ethernet interrupt

            if (urd.sched.shouldReschedule()) {
                urd.sched.reschedule();
            }

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
const Allocator = std.mem.Allocator;
const arch = @import("arch").impl;
const common = @import("common");
const mem = common.mem;
const Console = common.Console;
const MemoryManager = mem.MemoryManager;
const IoAllocator = mem.IoAllocator;
const dd = @import("dd");
const rdd = @import("dd.zig");
const urd = @import("urthr");
const net = urd.net;
