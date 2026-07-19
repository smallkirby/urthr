pub const memmap = @import("memmap.zig");
pub const sync = @import("sync.zig");

/// Function signature of exception handler.
///
/// Returns null if the exception cannot be handled.
pub const ExceptionHandler = *const fn (u64) ?void;

/// Number of CPU cores in the system.
pub const num_cpus = 4;

/// Exception handler called when an IRQ occurs.
var exception_handler: ?ExceptionHandler = null;

/// Virtio block device instance.
var virtio_blk_dev: ?dd.VirtioBlk = null;

/// Virtio RNG device instance.
var virtio_rng_dev: ?dd.VirtioRng = null;

/// PCIe ECAM.
var ecam: dd.pci.EcamHost = undefined;

/// xHC device.
var xhc: ?*dd.usb.Xhc = null;

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

/// Early board initialization.
///
/// Sets up essential peripherals like UART.
///
/// Expects all virtual address range is identity-mapped.
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
        null,
        .device,
    ));
    try allocator.iounmap(memmap.pl011.start, memmap.pl011.size());
}

/// De-initialize loader resources.
pub fn deinitLoader() void {}

/// Initialize peripherals.
///
/// This function is called before exceptions are enabled.
pub fn initPeripherals1() common.mem.Error!void {
    // Interrupt controller.
    {
        const gicd = try urd.mem.phys.reserveAndRemap(
            "GICD",
            memmap.gicd.start,
            memmap.gicd.size(),
            null,
            .device,
        );
        const gicr = try urd.mem.phys.reserveAndRemap(
            "GICR",
            memmap.gicr.start,
            memmap.gicr.size(),
            null,
            .device,
        );
        const its = try urd.mem.phys.reserveAndRemap(
            "ITS",
            memmap.gicits.start,
            memmap.gicits.size(),
            null,
            .device,
        );
        arch.gicv3.setBase(
            gicd,
            .new(gicr, memmap.gicr.start),
            .new(its, memmap.gicits.start),
        );

        try arch.gicv3.initGlobal(urd.mem.page);
    }

    // PCIe ECAM.
    {
        const pci = try urd.mem.phys.reserveAndRemap(
            "PCIe ECAM",
            memmap.pci.start,
            memmap.pci.size(),
            null,
            .device,
        );
        ecam = dd.pci.EcamHost.init(pci);
    }
}

/// Initialize peripherals phase 2.
///
/// This function is called after exceptions are enabled.
pub fn initPeripherals2() urd.mem.Error!void {
    // virtio
    {
        const virtio_size = dd.virtio.mmio_space_size;

        // Scan for virtio-blk device.
        const virtio_base = try urd.mem.phys.reserveAndRemap(
            "virtio",
            memmap.virtio.start,
            util.roundup(memmap.virtio.size(), common.mem.size_4kib),
            null,
            .device,
        );

        // virtio-blk
        for (0..(memmap.virtio.size() / virtio_size)) |i| {
            const base = virtio_base + i * virtio_size;

            virtio_blk_dev = dd.VirtioBlk.init(
                base,
                urd.mem.page,
                urd.mem.bin,
            ) catch continue;

            log.info("Found virtio-blk device#{d}", .{i});
            break;
        }

        // virtio-rng
        for (0..(memmap.virtio.size() / virtio_size)) |i| {
            const base = virtio_base + i * virtio_size;

            virtio_rng_dev = dd.VirtioRng.init(
                base,
                urd.mem.page,
                urd.mem.bin,
            ) catch continue;

            log.info("Found virtio-rng device#{d}", .{i});
            break;
        }
    }
}

/// Initialize peripherals.
///
/// This function is called after initial task is spawned.
/// This function can spawn new threads.
pub fn initPeripherals3() common.mem.Error!void {
    // xHC
    outer: {
        const hc = ecam.interface();

        // Scan for xHC device.
        var scan_buf: [16]dd.pci.ScanResult = undefined;
        const results = hc.scan(0, &scan_buf);
        const xhcdev: dd.pci.ScanResult = for (results) |res| {
            if (std.meta.eql(dd.usb.Xhc.class, res.class)) {
                break res;
            }
        } else break :outer;

        // Configure device command register.
        const io = hc.getTypedIo(xhcdev.addr, dd.pci.HeaderType0);
        io.modifyReg(dd.pci.HeaderCommandStatus, .{
            .memory_space_enable = true,
            .bus_master_enable = true,
        });

        // Check if BAR is valid.
        var barbuf: [1]dd.pci.BarInfo = undefined;
        const bar = blk: {
            const bars = io.parseBars(&barbuf);
            if (bars.len != barbuf.len) {
                break :outer;
            }
            if (bars[0].index != 0) {
                break :outer;
            }
            if (bars[0].type != .mem64) {
                break :outer;
            }

            break :blk bars[0];
        };

        // Configure BAR.
        const base, const phys = blk: {
            const phys_base = if (bar.address == 0)
                memmap.pci_mmio.start
            else
                bar.address & bar.address_mask;

            const base = try mem.phys.reserveAndRemap(
                "xhc",
                phys_base,
                bar.size(),
                null,
                .device,
            );
            io.setBarAddress(bar, phys_base);

            break :blk .{ base, phys_base };
        };
        log.debug("xHC: BAR#{}: 0x{X} (size=0x{X}) -> 0x{X}", .{ bar.index, phys, bar.size(), base });

        // Initialize xHC driver.
        const irq = arch.gicv3.lpi_base + 0;
        xhc = dd.usb.Xhc.init(base, irq, mem.dma.interface(0)) catch |err| {
            log.err("xHC initialization failed: {t}", .{err});
            break :outer;
        };

        // Register MSI-X.
        const devid: u32 = (@as(u32, xhcdev.addr.bus) << 8) |
            (@as(u32, xhcdev.addr.device) << 3) |
            @as(u32, xhcdev.addr.function);
        const msg = arch.gicv3.registerLpi(
            devid,
            1,
            irq,
            mem.page,
        ) catch |err| {
            log.err("Failed to register LPIs for xHC: {t}", .{err});
            break :outer;
        };
        const msix = dd.pci.parseMsixConfig(hc, xhcdev.addr) orelse {
            log.err("Failed to parse MSI-X configuration for xHC.", .{});
            break :outer;
        };
        const table = dd.pci.MsixTable{
            .base = base + msix.table_offset,
        };
        table.setEntry(0, msg, 0);
        table.maskEntry(0, false);
        dd.pci.enableMsix(hc, xhcdev.addr, msix.cap_offset);
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
    // `virt` target doest not have to maintain cache coherency!
    const f = struct {
        fn f() void {}
    }.f;
    arch.smp.wakePsci(core, entry, stack, f);
}

/// Fill the given buffer with random data.
pub fn getRandom(buf: []u8) void {
    rtt.expect(virtio_rng_dev != null);

    const random = virtio_rng_dev.?.read(buf.len, urd.mem.page) catch {
        @panic("Failed to read from virtio RNG device.");
    };
    @memcpy(buf, random);
}

/// Set the exception handler for IRQs.
pub fn initIrqGlobal(f: ExceptionHandler) void {
    // Set exception handler stub.
    exception_handler = f;

    // Set exception handler.
    arch.intr.setHandler(handleIrq);
}

/// Initialize GIC for the calling AP.
pub fn initIrqLocal() common.mem.PageAllocator.Error!void {
    // Initialize CPU interface.
    try arch.gicv3.initLocal(urd.mem.page);

    // Initialize exception handling for this CPU.
    arch.exception.initLocal();
}

/// Enable an interrupt by ID.
pub fn enableIrq(id: usize) void {
    arch.gicv3.enableIrq(id);
}

/// IRQ handler function.
fn handleIrq() ?void {
    const intid = arch.gicv3.readIar();

    if (exception_handler) |handler| {
        if (handler(intid)) |_| {
            arch.gicv3.eoi(intid);

            if (urd.sched.shouldReschedule()) {
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
    return if (virtio_blk_dev) |*dev|
        dev.interface()
    else
        null;
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
const log = std.log.scoped(.virt);
const arch = @import("arch").impl;
const common = @import("common");
const rtt = common.rtt;
const util = common.util;
const Console = common.Console;
const IoAllocator = common.mem.IoAllocator;
const PageAllocator = common.mem.PageAllocator;
const Pair = common.Pair;
const urd = @import("urthr");
const mem = urd.mem;
const dd = @import("dd");
