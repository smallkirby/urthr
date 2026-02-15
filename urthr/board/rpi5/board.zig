pub const memmap = @import("memmap.zig");

/// Function signature of exception handler.
///
/// Returns null if the exception cannot be handled.
pub const ExceptionHandler = *const fn (u64) ?void;

/// Exception handler called when an IRQ occurs.
var exception_handler: ?ExceptionHandler = null;

/// GEM controller instance.
var gem: dd.net.Gem = undefined;
/// GEM network device instance.
var gemdev: *net.Device = undefined;

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

        // Register network device.
        // TODO: should we register a device here?
        gemdev = GemDevice.new(mm.general) catch {
            @panic("Failed to create GEM network device");
        };
        urd.net.registerDevice(gemdev);

        // TODO: should we create an interface here?
        const ipif = try urd.net.ip.createInterface(
            net.ip.IpAddr.from("127.1.2.3") catch unreachable, // TODO
            net.ip.IpAddr.from("255.255.255.0") catch unreachable, // TODO
            mm.general,
        );
        try gemdev.appendInterface(ipif);
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

            // Reschedule if needed.
            if (urd.sched.getCurrent().need_resched) {
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

/// Handle GEM interrupt.
fn handleGemIrq() void {
    var buffer: [dd.net.Gem.mtu_all]u8 = undefined;

    while (gem.tryGetRx(&buffer)) |data| {
        net.ether.inputFrame(gemdev, data);
    }

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
// Network
// =============================================================

const GemDevice = struct {
    const Self = @This();

    const vtable = net.Device.Vtable{
        .open = null,
        .output = outputImpl,
    };

    /// Create a new GEM network device.
    pub fn new(allocator: Allocator) net.Error!*net.Device {
        const device = try allocator.create(net.Device);
        errdefer allocator.destroy(device);

        const flags = net.Device.Flag{
            .up = true,
        };

        device.* = .{
            .ctx = @ptrCast(&gem),
            .vtable = vtable,
            .mtu = dd.net.Gem.mtu,
            .flags = flags,
            .dev_type = .ether,
            .addr = undefined,
        };
        const mac_addr = gem.getMacAddr();
        @memcpy(device.addr[0..mac_addr.len], &mac_addr);

        return device;
    }

    fn outputImpl(dev: *net.Device, prot: net.Protocol, data: []const u8) net.Error!void {
        _ = dev;
        _ = prot;
        _ = data;

        urd.unimplemented("gement.outputImpl");
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
