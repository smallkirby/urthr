pub const memmap = @import("memmap.zig");
pub const sync = @import("sync.zig");

/// Function signature of exception handler.
///
/// Returns null if the exception cannot be handled.
pub const ExceptionHandler = *const fn (u64) ?void;

/// Exception handler called when an IRQ occurs.
var exception_handler: ?ExceptionHandler = null;

/// Hart IDs of all CPUs.
const hart_ids = [_]usize{ 0, 1, 2, 3 };
/// Number of CPU cores in the system.
pub const num_cpus = hart_ids.len;

/// Vector used for the TLB shootdown IPI.
pub const tlb_shootdown_vector = 0;
/// Vector used for the reschedule IPI.
pub const resched_vector = 1;

const todo = "TODO: RISC-V: not supported yet";

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
pub fn initPeripherals1() common.mem.Error!void {}

/// Initialize peripherals phase 2.
///
/// This function is called after exceptions are enabled.
pub fn initPeripherals2() urd.mem.Error!void {}

/// Initialize peripherals.
///
/// This function is called after initial task is spawned.
/// This function can spawn new threads.
pub fn initPeripherals3() common.mem.Error!void {}

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
    arch.smp.wake(smpHartIdOf(core), @ptrFromInt(entry), stack);
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

/// Set the exception handler for IRQs.
pub fn initIrqGlobal(f: ExceptionHandler) void {
    // Set exception handler stub.
    exception_handler = f;

    // Set exception handler.
    arch.intr.setHandler(handleIrq);
}

/// Initialize interrupts for the calling AP.
pub fn initIrqLocal() common.mem.PageAllocator.Error!void {
    arch.exception.initLocal();
}

/// IRQ handler function.
fn handleIrq() ?void {
    if (exception_handler) |handler| {
        const ret = switch (arch.exception.getIrqCode()) {
            .ssi, .sti => |code| handler(@backingInt(code)),
            else => null,
        };

        if (urd.sched.shouldReschedule()) {
            urd.sched.reschedule();
        }

        return ret;
    } else {
        return null;
    }
}

/// Enable an interrupt by ID.
pub fn enableIrq(id: usize) void {
    switch (id) {
        arch.timer.ppi_intid => arch.timer.enable(),
        tlb_shootdown_vector, resched_vector => {}, // TODO
        else => @panic(todo),
    }
}

/// Send an IPI to all cores except the caller.
pub fn sendIpiAll(_: u64) void {
    @panic(todo);
}

/// Send an IPI to the core of the given logical CPU ID.
pub fn sendIpi(_: usize, _: u64) void {
    @panic(todo);
}

/// Get the block device interface.
pub fn getBlockDevice() ?common.block.Device {
    return null;
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
    const finisher: *volatile u32 = @ptrFromInt(memmap.sifive_test.start);
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

/// Get the command line passed by the host.
pub fn getCmdline() !?[]const []const u8 {
    return null;
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
const arch = @import("arch").impl;
const common = @import("common");
const dd = @import("dd");
const Console = common.Console;
const IoAllocator = common.mem.IoAllocator;
const PageAllocator = common.mem.PageAllocator;
const urd = @import("urthr");
