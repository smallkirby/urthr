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

/// Early board initialization.
///
/// Sets up essential peripherals like GPIO and UART.
///
/// Expects all virtual address range is identity-mapped.
pub fn boot() void {
    // Setup GPIO.
    rdd.gpio.setBase(map.gpio.start);

    // Setup PL011 UART.
    dd.pl011.setBase(map.pl011.start);
    rdd.gpio.selectAltFn(14, .alt0); // TXD0
    rdd.gpio.selectAltFn(15, .alt0); // RXD0
    dd.pl011.init(48_000_000, 921_600); // 48 MHz, 921600 bps

    // Setup PM.
    rdd.pm.setBase(map.pm.start);
}

/// Map new I/O memory regions.
pub fn remap(allocator: IoAllocator) IoAllocator.Error!void {
    // GPIO
    rdd.gpio.setBase(try allocator.reserveAndRemap(
        "GPIO",
        map.gpio.start,
        map.gpio.size(),
        null,
        .device,
    ));

    // PL011 UART.
    dd.pl011.setBase(try allocator.reserveAndRemap(
        "PL011",
        map.pl011.start,
        map.pl011.size(),
        null,
        .device,
    ));
    try allocator.iounmap(map.pl011.start, map.pl011.size());

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

/// Initialize peripherals.
///
/// This function is called before exceptions are enabled.
pub fn initPeripherals1() urd.mem.Error!void {
    // Interrupt controller.
    {
        arch.gicv2.setBase(try urd.mem.phys.reserveAndRemap(
            "GIC",
            map.gic.start,
            map.gic.size(),
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

    // Mailbox.
    {
        const base = try urd.mem.phys.reserveAndRemap(
            "VCMBOX",
            memmap.mbox.start,
            memmap.mbox.size(),
            null,
            .device,
        );
        rdd.vcmbox.setBase(base + memmap.mbox_offset);
    }

    // Framebuffer
    {
        rdd.dma.setupChannel(memcpy_dma_chan);

        rdd.FrameBuffer.init(
            urd.mem.phys,
            urd.mem.page,
            .{ .memcpy = dmaMemcpy },
        ) catch |err| {
            log.err("framebuffer initialization failed: {t}", .{err});
        };

        urd.console.addBackend(rdd.FrameBuffer.getConsole()) catch |err| {
            log.warn("failed to add console backend: {}", .{err});
        };
    }
}

/// Initialize peripherals.
///
/// This function is called after exceptions are enabled.
pub fn initPeripherals2() urd.mem.Error!void {
    // SDHC
    {
        const base = try urd.mem.phys.reserveAndRemap(
            "SDHC",
            memmap.sdhost.start,
            memmap.sdhost.size(),
            null,
            .device,
        );
        dd.sdhc.setBase(base);
        dd.sdhc.init(
            50_000_000, // 50 MHz
            urd.mem.dma.interface(0),
        );
    }
}

/// Initialize peripherals.
///
/// This function is called after initial task is spawned.
/// This function can spawn new threads.
pub fn initPeripherals3() common.mem.Error!void {}

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
    // Map the spin table page.
    const page = try urd.mem.phys.ioremap(
        std.mem.alignBackward(usize, memmap.cpu_spintable, urd.mem.page_size),
        urd.mem.page_size,
        .normal,
    );
    defer urd.mem.phys.iounmap(page, urd.mem.page_size) catch {};
    const spintable = page + (memmap.cpu_spintable % urd.mem.page_size);

    // Wakeup the core.
    arch.smp.wakeSpin(
        core,
        spintable + core * 8,
        @ptrFromInt(entry),
        stack,
        sync.cleanAllDataCache,
    );
}

/// Fill the given buffer with random data.
pub fn getRandom(buf: []u8) void {
    _ = dd.fake_rng.read(buf);
}

/// De-initialize loader resources.
pub fn deinitLoader() void {}

/// Set the exception handler for IRQs.
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

/// IRQ handler function.
fn handleIrq() ?void {
    const iar = arch.gicv2.readIar();
    const intid = iar.interrupt_id;

    if (exception_handler) |handler| {
        if (handler(intid)) |_| {
            arch.gicv2.eoi(iar);

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
// Internals
// =============================================================

/// DMA channel used for memcpy.
const memcpy_dma_chan = 0;

/// DMA-accelerated memcpy.
fn dmaMemcpy(dst: usize, src: usize, len: usize) void {
    rdd.dma.memcpy(memcpy_dma_chan, src, dst, len);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.rpi4b);
const arch = @import("arch").impl;
const options = @import("options");
const common = @import("common");
const bits = common.bits;
const rtt = common.rtt;
const Console = common.Console;
const IoAllocator = common.mem.IoAllocator;
const urd = @import("urthr");
const dd = @import("dd");
const map = @import("memmap.zig");
const rdd = @import("dd.zig");
