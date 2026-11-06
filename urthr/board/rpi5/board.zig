pub const memmap = @import("memmap.zig");
pub const sync = @import("sync.zig");

/// Function signature of exception handler.
///
/// Returns null if the exception cannot be handled.
pub const ExceptionHandler = *const fn (u64) ?void;

/// Number of CPU cores in the system.
pub const num_cpus = 4;

/// SGI ID used for the TLB shootdown IPI.
pub const tlb_shootdown_vector = 0;
/// SGI ID used for the reschedule IPI.
pub const resched_vector = 1;

/// Exception handler called when an IRQ occurs.
var exception_handler: ?ExceptionHandler = null;

/// MAC address of GEM controller.
const gem_mac = net.ether.MacAddr.encode("B8:27:EB:00:00:00");

/// xHC controller.
var xhc: ?*dd.usb.Xhc = null;

/// Stash the loader-provided boot info for later use.
pub fn setBoardInfo(_: usize) void {}

/// Get available memory region that we can use for booting the kernel.
pub fn getBootRegion(comptime size: usize) common.Range {
    urd.comptimeAssert(
        memmap.loader + size <= memmap.loader_reserved.start,
        \\Region reserved for boot-time allocator overwraps the bootloader region.
        \\  Loader Start + Work Buffer = 0x{X:0>8}
        \\  Loader Reserved Start      = 0x{X:0>8}
    ,
        .{ memmap.loader + size, memmap.loader_reserved.start },
    );

    return common.Range{
        .start = memmap.loader,
        .end = memmap.loader + size,
    };
}

/// Get the physical address kernel was loaded at.
pub fn getKernelPaddr() usize {
    return memmap.kernel;
}

/// Get the DRAM region.
pub fn getDramRegion() []const common.Range {
    return &memmap.drams;
}

/// Get the I/O regions that must be identity-mapped during boot.
pub inline fn getIoTempMaps() []const common.Range {
    return &[_]common.Range{
        memmap.pl011,
        memmap.pm,
    };
}

/// Get the normal-memory regions that must be identity-mapped during boot.
pub inline fn getNormalTempMaps() []const common.Range {
    return &.{};
}

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
pub fn remapIo(allocator: IoAllocator) IoAllocator.Error!void {
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

/// Move new normal memory regions.
pub fn remapNormal(_: PageAllocator, _: PageAllocator) common.mem.Error!void {}

/// De-initialize loader resources.
pub fn deinitLoader() void {}

/// Initialize peripherals.
///
/// This function is called before exceptions are enabled.
pub fn initPeripherals1() (urd.mem.Error || net.Error)!void {
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

    // DMA
    {
        rdd.dma.setBase(try urd.mem.phys.reserveAndRemap(
            "DMA",
            memmap.dma.start,
            memmap.dma.size(),
            null,
            .device,
        ));
        try rdd.dma.init();
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
        rdd.pcie.init();
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

    // Framebuffer.
    // TODO: The output is fixed to HDMI1.
    log.info("Initializing HVS.", .{});
    outer: {
        const chan_index = 1;

        const hvsbase = try urd.mem.phys.reserveAndRemap(
            "HVS",
            memmap.hvs.start,
            memmap.hvs.size(),
            null,
            .device,
        );
        rdd.hvs.setBase(hvsbase, urd.mem.dma.interface(0));

        const ddc = try urd.mem.phys.reserveAndRemap(
            "HDMI DDC",
            memmap.hdmi_ddc.start,
            memmap.hdmi_ddc.size(),
            null,
            .device,
        );
        var bsc = dd.i2c.BrcmStb.init(
            ddc + memmap.hdmi1_ddc_offset,
            .hz_97500,
        );

        rdd.hvs.init() catch |err| {
            log.err("HVS initialization failed: {t}", .{err});
            break :outer;
        };

        const mode = selectVideoMode(chan_index, bsc.adapter()) orelse {
            log.err("No supported display mode", .{});
            break :outer;
        };
        log.info("Display mode: {d}x{d} (VIC#{d})", .{ mode.hdisplay, mode.vdisplay, mode.vic });

        const chan = rdd.hvs.Channel{
            .index = chan_index,
            .width = mode.hdisplay,
            .height = mode.vdisplay,
        };

        // HDMI.
        {
            const hdmibase = try urd.mem.phys.reserveAndRemap(
                "HDMI",
                memmap.hdmi.start,
                memmap.hdmi.size(),
                null,
                .device,
            );
            const hdbase = try urd.mem.phys.reserveAndRemap(
                "HDMI HD",
                memmap.hdmi_hd.start,
                memmap.hdmi_hd.size(),
                null,
                .device,
            );
            rdd.hdmi.setBase(hdmibase, hdbase, urd.mem.dma.interface(0));
            rdd.hdmi.reset(chan.index);
        }

        // Install the display list of the framebuffer.
        const fb = rdd.hvs.createFramebuffer(urd.mem.bin, chan, .{
            .memcpy = dmaMemcpy,
        }) catch |err| {
            log.err("HVS framebuffer creation failed: {t}", .{err});
            break :outer;
        };
        // HVS channel enable.
        rdd.hvs.initChannel(chan.index, mode.hdisplay, mode.vdisplay);

        // Pre CRTC configure.
        {
            rdd.hdmi.initClocks(mode) catch |err| {
                log.err("HDMI clock configuration failed: {t}", .{err});
            };
            rdd.hdmi.initPhy(chan.index, mode) catch |err| {
                log.err("HDMI PHY configuration failed: {t}", .{err});
            };
            rdd.hdmi.initScheduler(chan.index);
            rdd.hdmi.setTimings(chan.index, mode);
        }

        // Pixel Valve.
        pv: {
            const pvbase = try urd.mem.phys.reserveAndRemap(
                "PV",
                memmap.pv.start,
                memmap.pv.size(),
                null,
                .device,
            );
            rdd.pv.setBase(pvbase);

            rdd.pv.configure(chan.index, .hdmi1, mode) catch |err| {
                log.err("PV configuration failed: {t}", .{err});
                break :pv;
            };
            rdd.pv.enable(chan.index) catch |err| {
                log.err("PV enabling failed: {t}", .{err});
                break :pv;
            };

            // Pre CRTC enable.
            rdd.hdmi.setupCsc(chan.index, mode);
            rdd.hdmi.initFifo(chan.index);

            // CRTC enable.
            rdd.pv.enableVideo(chan.index) catch |err| {
                log.err("PV video enabling failed: {t}", .{err});
                break :pv;
            };

            // Post CRTC enable.
            rdd.hdmi.enableVideo(chan.index, mode);
            rdd.hdmi.enableHdmiMode(chan.index) catch |err| {
                log.err("HDMI mode activation failed: {t}", .{err});
            };
            rdd.hdmi.setAviPacket(chan.index, mode) catch |err| {
                log.err("HDMI AVI InfoFrame transmission failed: {t}", .{err});
            };
            rdd.hdmi.setSpdPacket(chan.index) catch |err| {
                log.err("HDMI SPD InfoFrame transmission failed: {t}", .{err});
            };
            rdd.hdmi.recenterFifo(chan.index) catch |err| {
                log.err("HDMI FIFO recentering failed: {t}", .{err});
            };
        }

        const fbcon = urd.mem.bin.create(FbConsole) catch unreachable;
        fbcon.* = FbConsole.init(fb);
        urd.console.addBackend(fbcon.interface()) catch |err| {
            log.warn("failed to add console backend: {t}", .{err});
        };
    }
}

/// Initialize peripherals.
///
/// This function is called after exceptions are enabled.
pub fn initPeripherals2() (urd.mem.Error || net.Error)!void {
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
}

/// Initialize peripherals.
///
/// This function is called after initial task is spawned.
/// This function can spawn new threads.
pub fn initPeripherals3() (urd.mem.Error || net.Error)!void {
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
            urd.mem.dma.interface(0),
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
            .comptimeParse("0.0.0.0"),
            .comptimeParse("0.0.0.0"),
            urd.mem.bin,
        );
        try gemdev.appendInterface(iface);
    }

    // xHC
    log.info("Initializing xHC.", .{});
    blkxhc: {
        const base = rdd.rp1.getUsbHost1Base();
        const intid = rdd.rp1.getIrqNumber(.usb1);

        // Initialize xHC driver.
        xhc = dd.usb.Xhc.init(base, intid, rdd.pcie.getDmaAllocator()) catch |err| {
            log.err("xHC initialization failed: {t}", .{err});
            break :blkxhc;
        };
    }
    if (xhc) |x| outer: {
        x.reset() catch |err| {
            log.err("xHC reset failed: {t}", .{err});
            break :outer;
        };

        x.setup() catch |err| {
            log.err("xHC setup failed: {t}", .{err});
            break :outer;
        };

        // Clear any stale RP1 USB1 auto-mask before arming GIC.
        rdd.rp1.ackMsix(.usb1);
        // Enable xHC interrupt.
        const intid = rdd.rp1.getIrqNumber(.usb1);
        arch.gicv2.setTrigger(intid, .edge);
        arch.gicv2.enableIrq(intid);

        x.run();

        x.scan() catch |err| {
            log.err("xHC scan failed: {t}", .{err});
            break :outer;
        };
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
        urd.sched.getCurrent().vmm.as,
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
        urd.sched.getCurrent().vmm.as,
        kentry,
        kentry,
        .{},
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
pub fn initIrqLocal() urd.mem.Error!void {
    // Initialize CPU interface.
    arch.gicv2.initLocal();

    // Initialize exception handling for this CPU.
    arch.exception.initLocal();
}

/// Enable an interrupt by ID.
pub fn enableIrq(id: usize) void {
    arch.gicv2.enableIrq(id);
}

/// Send an IPI to all cores except the caller.
pub fn sendIpiAll(id: u64) void {
    arch.gicv2.sendSgi(@intCast(id), .all);
}

/// Send an IPI to the core of the given logical CPU ID.
pub fn sendIpi(cpu: usize, id: u64) void {
    arch.gicv2.sendSgi(@intCast(id), .{
        .target = &.{@intCast(cpu)},
    });
}

/// IRQ handler function.
fn handleIrq() ?void {
    const iar = arch.gicv2.readIar();
    const intid = iar.interrupt_id;

    if (rdd.rp1.tryGetMsix(intid)) |msix| {
        rdd.rp1.ackMsix(msix);
    }

    if (exception_handler) |handler| {
        if (handler(intid)) |_| {
            arch.gicv2.eoi(iar);

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

/// Trigger a system cold reset.
///
/// This function returns before the reset actually happens.
///
/// Argument is ignored.
pub fn reset(_: u8) void {
    rdd.pm.reset();
}

/// Power off the system.
pub fn powerOff() noreturn {
    log.warn("power-off is not supported on this board. Falling back to reset", .{});

    reset(0);
    while (true) {
        arch.halt();
    }
}

/// Get a command line arguments.
pub fn getCmdline() !?[]const []const u8 {
    return null;
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
// Internals
// =============================================================

// =============================================================
// Video

/// EDID blocks of the sink.
const Sink = struct {
    /// Base block.
    base: edid.Base,
    /// The first CTA-861 extension block.
    cta: ?edid.Cta,
};

/// Select the display mode using the information from the EDID.
///
/// The preferred timing is used if usable.
/// Otherwise, the best one is selected from all the usable modes
/// among the VIC list in the CTA-861 block, and the DTDs in both blocks.
///
/// If no candidate mode is found, falls back to VIC#16.
fn selectVideoMode(chan: usize, ddc: dd.i2c.Adapter) ?Mode {
    const fallback = Mode.fromVic(16) orelse unreachable;

    // Read EDID base block and the first CTA-861 extension block.
    var base_block: [edid.block_size]u8 = undefined;
    var cta_block: [edid.block_size]u8 = undefined;
    const sink = readEdid(
        ddc,
        &base_block,
        &cta_block,
    ) orelse return fallback;

    // Use the preferred timing in the base block.
    var base_iter = sink.base.modes();
    if (sink.base.hasPreferredTiming()) {
        if (base_iter.next()) |mode| {
            if (canOutput(chan, mode)) return mode;
        }
    }

    // Select the best mode from the remaining modes in the base block.
    var best: ?Mode = null;
    updateBestAll(chan, &best, &base_iter);
    // Select the best mode from the VIC list and the pre-defined table.
    if (sink.cta) |cta| {
        for (Mode.cta_modes) |mode| {
            if (cta.hasVic(mode.vic)) {
                updateBest(chan, &best, mode);
            }
        }
        var cta_modes = cta.modes();
        updateBestAll(chan, &best, &cta_modes);
    }

    return best orelse {
        log.warn("EDID has no supported mode", .{});
        return fallback;
    };
}

/// Consider all the remaining modes of the iterator.
fn updateBestAll(chan: usize, best: *?Mode, it: *edid.ModeIterator) void {
    while (it.next()) |mode| {
        updateBest(chan, best, mode);
    }
}

/// Update the best mode if the candidate is usable and better.
fn updateBest(chan: usize, best: *?Mode, cand: Mode) void {
    if (!canOutput(chan, cand)) return;
    if (best.*) |b| {
        if (!cand.isBetterThan(b)) return;
    }
    best.* = cand;
}

/// Check if both the PV and HDMI can output the mode.
fn canOutput(chan: usize, mode: Mode) bool {
    return rdd.pv.supports(chan, mode) and rdd.hdmi.supports(mode);
}

/// Read the base block and the first CTA-861 extension block into the buffers.
fn readEdid(
    ddc: dd.i2c.Adapter,
    base_block: *[edid.block_size]u8,
    cta_block: *[edid.block_size]u8,
) ?Sink {
    // Read the EDID base block.
    base_block.* = edid.readBlockI2c(ddc, 0) catch |err| {
        log.warn("EDID read failed: {t}", .{err});
        return null;
    };
    const base = edid.Base.parse(base_block) orelse {
        log.warn("EDID base block is invalid", .{});
        return null;
    };

    // Find the first CTA-861 extension block.
    var cta: ?edid.Cta = null;
    var index: usize = 1;
    while (index <= base.extensionCount() and cta == null) : (index += 1) {
        cta_block.* = edid.readBlockI2c(ddc, index) catch |err| {
            log.warn("EDID extension block#{d} read failed: {t}", .{ index, err });
            break;
        };
        cta = edid.Cta.parse(cta_block);
    }
    if (cta == null) {
        log.warn("No CTA-861 extension block found", .{});
    }

    return .{ .base = base, .cta = cta };
}

// =============================================================
// DMA Engine

/// DMA channel used for memcpy.
const memcpy_dma_chan = 6;

/// DMA-accelerated memcpy.
fn dmaMemcpy(_: *anyopaque, dst: usize, src: usize, len: usize) void {
    rdd.dma.memcpy(memcpy_dma_chan, src, dst, len);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.rpi5);
const Allocator = std.mem.Allocator;
const arch = @import("arch").impl;
const common = @import("common");
const Console = common.Console;
const FbConsole = common.FbConsole;
const IoAllocator = common.mem.IoAllocator;
const PageAllocator = common.mem.PageAllocator;
const dd = @import("dd");
const edid = dd.video.edid;
const Mode = dd.video.Mode;
const rdd = @import("dd.zig");
const urd = @import("urthr");
const net = urd.net;
