pub const memmap = @import("memmap.zig");
pub const irq = @import("irq.zig");
pub const sync = @import("sync.zig");

/// Base virtual base address of the SiFive test device.
var sifive_test_base: usize = 0;
/// Base address of the virtio MMIO devices.
var virtio_base: usize = undefined;

/// Peripheral devices on the board.
var devices = struct {
    /// Virtio block device.
    virtio_blk: ?dd.VirtioBlk = null,
    /// Virtio GPU device.
    virtio_gpu: ?dd.VirtioGpu = null,

    /// Framebuffer console instance.
    fb_console: FbConsole = undefined,
}{};

/// Hart IDs of all CPUs.
const hart_ids = [_]usize{ 0, 1, 2, 3 };
/// Number of CPU cores in the system.
pub const num_cpus = hart_ids.len;

/// Stash the loader-provided boot info for later use.
pub fn setBoardInfo(_: usize) void {}

/// Get available memory region that we can use for booting the kernel.
pub fn getBootRegion(comptime size: usize) common.Range {
    return common.Range{
        .start = memmap.boot_work,
        .end = memmap.boot_work + size,
    };
}

/// Get the physical address kernel was loaded at.
pub fn getKernelPaddr() usize {
    return memmap.kernel;
}

/// Get the list of usable DRAM regions.
pub fn getDramRegion() []const common.Range {
    return &memmap.drams;
}

/// Get the I/O regions that must be identity-mapped during boot.
pub inline fn getIoTempMaps() []const common.Range {
    return &[_]common.Range{
        memmap.uart,
    };
}

/// Get the normal-memory regions that must be identity-mapped during boot.
pub inline fn getNormalTempMaps() []const common.Range {
    return &.{};
}

/// Early board initialization.
///
/// The UART is already configured by the firmware.
pub fn boot() void {
    // Init NS16550 UART.
    dd.uart16550.setBase(memmap.uart.start);

    // Set timer frequency.
    arch.timer.setFreq(memmap.timer_freq);

    // Set hart IDs.
    arch.smp.setHartIds(&hart_ids);

    // Set PLIC context for the boot core.
    irq.setPlicContext(0, arch.getCoreId());
}

/// Map new I/O memory regions.
pub fn remapIo(allocator: IoAllocator) IoAllocator.Error!void {
    // Remap UART.
    dd.uart16550.setBase(try allocator.reserveAndRemap(
        "NS16550",
        memmap.uart.start,
        memmap.uart.size(),
        null,
        .device,
    ));
    try allocator.iounmap(memmap.uart.start, memmap.uart.size());

    // Reserve DRAM for MROM.
    _ = try allocator.reserve(
        "MROM",
        memmap.mrom.start,
        memmap.mrom.size(),
        null,
    );
}

/// Move new normal memory regions.
pub fn remapNormal(_: PageAllocator, _: PageAllocator) common.mem.Error!void {}

/// De-initialize loader resources.
pub fn deinitLoader() void {}

/// Initialize peripherals.
///
/// This function is called before exceptions are enabled.
pub fn initPeripherals1() common.mem.Error!void {
    // SiFive test device.
    sifive_test_base = try urd.mem.phys.reserveAndRemap(
        "SiFive test",
        memmap.sifive_test.start,
        memmap.sifive_test.size(),
        null,
        .device,
    );

    // PLIC.
    try irq.initController();

    // QEMU fw_cfg.
    fwcfg.setBase(try urd.mem.phys.reserveAndRemap(
        "fw_cfg",
        memmap.fw_cfg.start,
        memmap.fw_cfg.size(),
        null,
        .device,
    ));
}

/// Initialize peripherals phase 2.
///
/// This function is called after exceptions are enabled.
pub fn initPeripherals2() urd.mem.Error!void {
    // virtio
    virtio_base = try urd.mem.phys.reserveAndRemap(
        "virtio",
        memmap.virtio.start,
        memmap.virtio.size(),
        null,
        .device,
    );
}

/// Initialize peripherals.
///
/// This function is called after initial task is spawned.
/// This function can spawn new threads.
pub fn initPeripherals3() common.mem.Error!void {
    // virtio-blk
    for (0..(memmap.virtio.size() / memmap.virtio_stride)) |i| {
        const base = virtio_base + i * memmap.virtio_stride;

        const dev = if (dd.virtio.mmio.init(
            base,
            .block,
            dd.VirtioBlk.Features{ .flush = true },
            urd.mem.page,
            urd.mem.bin,
        )) |result| if (result) |dev| dev else {
            continue;
        } else |_| {
            continue;
        };
        devices.virtio_blk = dd.VirtioBlk.init(
            dev.interface(),
            urd.mem.dma.interface(0),
            urd.mem.bin,
        ) catch continue;

        // Register IRQ.
        const vector = irq.plic_vector_base + memmap.virtio_first_source + i;
        irq.enable(@fromBackingInt(@intCast(vector)));
        devices.virtio_blk.?.registerIrq(vector);

        log.info("Found virtio-blk device#{d}", .{i});
        break;
    }

    // virtio-gpu
    for (0..(memmap.virtio.size() / memmap.virtio_stride)) |i| {
        const base = virtio_base + i * memmap.virtio_stride;

        const dev = if (dd.virtio.mmio.init(
            base,
            .gpu,
            dd.VirtioGpu.Features{},
            urd.mem.page,
            urd.mem.bin,
        )) |result| if (result) |dev| dev else {
            continue;
        } else |_| {
            continue;
        };
        devices.virtio_gpu = dd.VirtioGpu.init(
            dev.interface(),
            urd.mem.dma.interface(0),
            urd.mem.bin,
        ) catch |err| {
            log.warn("Failed to initialize virtio-gpu: {t}", .{err});
            break;
        };
        const gpu = &devices.virtio_gpu.?;

        // Register IRQ.
        const vector = irq.plic_vector_base + memmap.virtio_first_source + i;
        irq.enable(@fromBackingInt(@intCast(vector)));
        gpu.registerIrq(vector);

        // Setup the framebuffer and expose it as /dev/fbN.
        const displays = gpu.getDisplayInfo(urd.mem.bin) catch |err| {
            log.warn("Failed to get display info: {t}", .{err});
            break;
        };
        defer urd.mem.bin.free(displays);
        if (displays.len == 0) {
            log.warn("No enabled display found.", .{});
            break;
        }

        const fb = gpu.setupFramebuffer(displays[0]) catch |err| {
            log.warn("Failed to setup framebuffer: {t}", .{err});
            break;
        };
        urd.fb.addBackend(fb) catch |err| {
            log.warn("failed to add framebuffer backend: {t}", .{err});
        };

        // Register framebuffer console backend.
        devices.fb_console = FbConsole.init(fb);
        urd.console.addBackend(devices.fb_console.interface()) catch |err| {
            log.warn("Failed to add framebuffer console backend: {t}", .{err});
        };

        log.info("Found virtio-gpu device#{d}", .{i});
        break;
    }
}

/// Prepare for waking up secondary cores.
///
/// Identity-maps a trampoline page.
pub fn prepareSubcoreWakeup() urd.mem.Error!void {
    // Allocate a page for the trampoline blob.
    const blob = try urd.mem.page.allocPagesV(1);
    errdefer urd.mem.page.freePagesV(blob);

    // Install the trampoline blob into the allocated page.
    const pa = urd.mem.page.translateIntP(blob);
    arch.smp.trampoline_phys = pa;
    arch.smp.installTrampoline(blob);

    // Identity-map the trampoline page.
    try arch.mmu.map4kb(
        urd.sched.getCurrent().vmm.as,
        .{
            .va = arch.smp.trampoline_phys,
            .pa = arch.smp.trampoline_phys,
            .size = urd.mem.page_size,
            .perm = .kernel_rwx,
            .attr = .normal,
        },
        .{},
        urd.mem.page,
    );
}

/// De-initialize resources used for waking up secondary cores.
///
/// Removes the identity mapping of the trampoline page.
pub fn deinitSubcoreWakeup() void {
    arch.mmu.unmap4kb(
        urd.sched.getCurrent().vmm.as,
        arch.smp.trampoline_phys,
        urd.mem.page_size,
        .{},
        urd.mem.page,
    ) catch {};

    const pa: [*]u8 = @ptrFromInt(arch.smp.trampoline_phys);
    urd.mem.page.freePagesP(pa[0..urd.mem.page_size]);
}

/// Wakeup a secondary core.
///
/// This function returns before the core is actually awake.
/// The caller should wait for the core to be awake.
///
/// - core: Logical CPU ID to wake up.
/// - entry: Virtual address of the entry point.
/// - stack: Virtual address of the stack pointer.
pub fn wakeSubcore(core: usize, entry: usize, stack: usize) urd.mem.Error!void {
    const hartid = smpHartIdOf(core);
    irq.setPlicContext(core, hartid); // TODO: should not update here?

    arch.smp.wake(hartid, @ptrFromInt(entry), stack);
}

/// Get the hart ID of the given secondary logical harts.
///
/// Can be called only during early boot.
fn smpHartIdOf(logical: usize) usize {
    const boot_hart = arch.getCoreId();

    var n: usize = 0;
    for (hart_ids) |id| {
        if (id == boot_hart) continue;
        n += 1;
        if (n == logical) return id;
    }

    unreachable;
}

/// Fill the given buffer with random data.
pub fn getRandom(buf: []u8) void {
    _ = dd.fake_rng.read(buf);
}

/// Get the block device interface.
pub fn getBlockDevice() ?common.block.Device {
    return if (devices.virtio_blk) |*dev|
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

/// Trigger a system cold reset.
pub fn reset(status: u8) void {
    const finisher: *volatile u32 = @ptrFromInt(
        if (sifive_test_base != 0) sifive_test_base else memmap.sifive_test.start,
    );
    finisher.* = if (status == 0)
        0x5555
    else
        (@as(u32, status) << 16) | 0x3333;

    while (true) {
        arch.halt();
    }
}

/// Power off the system.
pub fn powerOff() noreturn {
    reset(0);

    while (true) {
        arch.halt();
    }
}

/// Get the command line passed by the host via a fw_cfg.
///
/// Callers are responsible for freeing the returned array and its contents.
pub fn getCmdline() !?[]const []const u8 {
    const file = fwcfg.lookupFile(urd.fwcfg_filename) orelse return null;
    if (file.size == 0) return null;

    const content = try fwcfg.readFile(file, urd.mem.bin);
    errdefer urd.mem.bin.free(content);

    var it = common.util.ShellWordIterator.init(content);
    var argv: std.array_list.Aligned([]const u8, null) = .empty;
    while (it.next()) |word| {
        argv.append(urd.mem.bin, word) catch break;
    }
    return argv.items;
}

/// Wrapper functions for console API.
const console = struct {
    fn putc(_: *anyopaque, c: u8) void {
        return dd.uart16550.putc(c);
    }

    fn flush(_: *anyopaque) void {
        return dd.uart16550.flush();
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.rv64v);
const carch = @import("arch");
const arch = carch.impl;
const common = @import("common");
const dd = @import("dd");
const fwcfg = dd.fwcfg;
const Console = common.Console;
const FbConsole = common.FbConsole;
const IoAllocator = common.mem.IoAllocator;
const PageAllocator = common.mem.PageAllocator;
const urd = @import("urthr");
