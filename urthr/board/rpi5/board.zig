pub const memmap = @import("memmap.zig");

/// Function signature of exception handler.
///
/// Returns null if the exception cannot be handled.
pub const ExceptionHandler = *const fn (u64) ?void;

/// Number of CPU cores in the system.
pub const num_cpus = 4;

/// Exception handler called when an IRQ occurs.
var exception_handler: ?ExceptionHandler = null;

/// MAC address of GEM controller.
const gem_mac = net.ether.MacAddr.encode("B8:27:EB:00:00:00");

/// Early board initialization.
///
/// Sets up essential peripherals like UART.
///
/// Expects all virtual address range is identity-mapped.
pub fn boot() void {
    // Setup PL011 UART.
    dd.pl011.setBase(memmap.pl011.start);
    dd.pl011.init(44_236_800, 921_600); // 44.237 MHz, 921600 bps

    // Setup PM.
    rdd.pm.setBase(memmap.pm.start);
}

/// Map new I/O memory regions.
pub fn remap(allocator: IoAllocator) IoAllocator.Error!void {
    // Reserved.
    _ = try allocator.reserve(
        "Reserved",
        0,
        memmap.drams[0].start,
        null,
    );

    // PL011 UART.
    dd.pl011.setBase(try allocator.reserveAndRemap(
        "PL011",
        memmap.pl011.start,
        memmap.pl011.size(),
        null,
        .device,
    ));
    try allocator.iounmap(memmap.pl011.start, memmap.pl011.size());

    // PM.
    rdd.pm.setBase(try allocator.reserveAndRemap(
        "PM",
        memmap.pm.start,
        memmap.pm.size(),
        null,
        .device,
    ));
    try allocator.iounmap(memmap.pm.start, memmap.pm.size());
}

/// De-initialize loader resources.
pub fn deinitLoader() void {}

/// Initialize peripherals.
pub fn initPeripherals() (common.mem.Error || net.Error)!void {
    // Interrupt controller.
    {
        arch.gicv2.setBase(try urd.mem.phys.reserveAndRemap(
            "GIC",
            memmap.gic.start,
            memmap.gic.size(),
            null,
            .device,
        ));
        arch.gicv2.initGlobal();
    }

    // PCIe.
    log.info("Initializing PCIe controller.", .{});
    {
        const pci = try urd.mem.phys.reserveAndRemap(
            "PCIe",
            memmap.pci.start,
            memmap.pci.size(),
            null,
            .device,
        );
        rdd.pcie.setBase(pci);
        rdd.pcie.init(urd.mem.page);
    }

    // Mailbox.
    {
        const base = try urd.mem.phys.reserveAndRemap(
            "VideoCore mailbox",
            memmap.mbox.start,
            memmap.mbox.size(),
            null,
            .device,
        );
        rdd.vcmbox.setBase(base + memmap.mbox_offset);
    }

    // RP1.
    log.info("Initializing RP1.", .{});
    {
        try rdd.rp1.init(urd.mem.phys);
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

    // RNG.
    log.info("Initializing RNG.", .{});
    {
        const rng = try urd.mem.phys.reserveAndRemap(
            "rng",
            memmap.rng.start,
            memmap.rng.size(),
            null,
            .device,
        );

        rdd.rng.setBase(rng);
        rdd.rng.init();
    }

    // SDHC.
    log.info("Initializing SDHC.", .{});
    {
        const sdbase = try urd.mem.phys.reserveAndRemap(
            "SDHC",
            memmap.sd.start,
            memmap.sd.size(),
            null,
            .device,
        );

        dd.sdhc.setBase(sdbase);
        dd.sdhc.init(
            50_000_000, // 50 MHz PLL base clock
            urd.mem.page,
        );
    }

    // Framebuffer.
    {
        rdd.FrameBuffer.init(
            urd.mem.phys,
            urd.mem.page,
            .{ .memcpy = null },
        ) catch |err| {
            log.err("framebuffer initialization failed: {t}", .{err});
        };
        urd.console.addBackend(rdd.FrameBuffer.getConsole()) catch |err| {
            log.warn("failed to add console backend: {t}", .{err});
        };
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
            urd.mem.bin,
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
            net.ip.IpAddr.comptimeParse("0.0.0.0"),
            urd.mem.bin,
        );
        try gemdev.appendInterface(iface);
    }
}

/// Prepare for waking up secondary cores.
pub fn prepareSubcoreWakeup() urd.mem.Error!void {
    // Identity-map the entry point page for secondary cores.
    const kentry = std.mem.alignBackward(
        usize,
        arch.smp.getIdentityAddress(),
        urd.mem.page_size,
    );
    try arch.mmu.map4kb(
        urd.mem.getInitPageTablePair(),
        .{
            .va = kentry,
            .pa = kentry,
            .size = urd.mem.page_size,
            .perm = .kernel_rwx,
            .attr = .normal,
        },
        .{},
        urd.mem.page,
    );
}

/// De-initialize resources used for waking up secondary cores.
pub fn deinitSubcoreWakeup() void {
    const kentry = std.mem.alignBackward(
        usize,
        arch.smp.getIdentityAddress(),
        urd.mem.page_size,
    );
    arch.mmu.unmap4kb(
        urd.mem.getInitPageTablePair(),
        kentry,
        kentry,
        urd.mem.page,
    ) catch {};
}

/// Wakeup a secondary core.
///
/// This function returns before the core is actually awake.
/// The caller should wait for the core to be awake.
///
/// - core: Core number to wake up.
/// - entry: Virtual address of the entry point.
/// - stack: Virtual address of the stack pointer.
pub fn wakeSubcore(core: usize, entry: usize, stack: usize) urd.mem.Error!void {
    // RPi5's core number is in Affinity 1 in MPIDR.
    arch.smp.wakePsci(
        core << 8,
        entry,
        stack,
        sync.cleanAllDataCache,
    );
}

/// Fill the given buffer with random data.
pub fn getRandom(buf: []u8) void {
    var count: usize = 0;

    while (count < buf.len) {
        const random = rdd.rng.read(buf[count..]);
        count += random.len;
    }
}

/// Initialize the exception handling common to all CPUs.
pub fn initIrqGlobal(f: ExceptionHandler) void {
    // Set exception handler stub.
    exception_handler = f;

    // Set exception handler.
    arch.intr.setHandler(handleIrq);
}

/// Initialize GIC for the calling AP.
pub fn initIrqLocal() void {
    // Initialize CPU interface.
    arch.gicv2.initLocal();

    // Initialize exception handling for this CPU.
    arch.exception.initLocal();
}

/// Enable an interrupt by ID.
pub fn enableIrq(id: usize) void {
    arch.gicv2.enableIrq(id);
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
const Console = common.Console;
const IoAllocator = common.mem.IoAllocator;
const dd = @import("dd");
const rdd = @import("dd.zig");
const sync = @import("sync.zig");
const urd = @import("urthr");
const net = urd.net;
