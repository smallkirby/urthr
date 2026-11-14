pub const memmap = @import("memmap.zig");
pub const sync = @import("sync.zig");

/// Function signature of exception handler.
///
/// Returns null if the exception cannot be handled.
pub const ExceptionHandler = *const fn (u64) ?void;

/// Exception handler called when an IRQ occurs.
var exception_handler: ?ExceptionHandler = null;

/// Vector number of the PLIC interrupt source 0.
///
/// This value is SW-defined.
const plic_vector_base: usize = 64;
/// PLIC context for S-mode of each logical CPU.
///
/// Indexed by the logical CPU core ID.
var plic_contexts: [num_cpus]usize = @splat(0);
/// Pending IPI vectors of each logical CPU.
///
/// RISC-V IPI cannot send arbitrary vector numbers,
/// so this variable tracks pending IPI to multiplex IPI requests.
var ipi_pending: [num_cpus]std.atomic.Value(u64) = @splat(.init(0));

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

    // Set PLIC context for the boot core.
    plic_contexts[0] = plicContextOf(arch.getCoreId());
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
    // PLIC.
    arch.plic.setBase(try urd.mem.phys.reserveAndRemap(
        "PLIC",
        memmap.plic.start,
        memmap.plic.size(),
        null,
        .device,
    ));
}

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
    const hartid = smpHartIdOf(core);
    plic_contexts[core] = plicContextOf(hartid); // TODO: should not update here?

    arch.smp.wake(hartid, @ptrFromInt(entry), stack);
}

/// Calculate the PLIC context for S-mode of the given hart.
///
/// This calculation depends on the platform-specific layout of PLIC contexts.
fn plicContextOf(hartid: usize) usize {
    return hartid * 2 + 1;
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
    // Initialize exception handling.
    arch.exception.initLocal();

    // Accept all external interrupts regardless of their priority.
    const me = arch.getCoreId();
    arch.plic.setThreshold(plicContextOf(me), 0);
    arch.exception.enableExternalIrq();

    // Unmask all maskable interrupts.
    arch.intr.unmaskAll();
}

/// IRQ handler function.
fn handleIrq() ?void {
    if (exception_handler) |handler| {
        const ret = switch (arch.exception.getIrqCode()) {
            .sti => |code| handler(@backingInt(code)),
            .ssi => handleIpi(handler),
            .sei => handlePlic(handler),
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

/// Dispatch pending IPIs of this core to the registered handlers.
fn handleIpi(handler: ExceptionHandler) ?void {
    // Clear the pending interrupt first.
    arch.exception.clearSoftwareIrq();

    // Handle all pending IPIs for this core.
    const me = urd.smp.getLogicalCoreId();
    var pending = ipi_pending[me].swap(0, .acq_rel);
    while (pending != 0) {
        const vector = @ctz(pending);
        pending &= pending - 1;
        _ = handler(vector);
    }
}

/// Dispatch the external interrupt claimed from PLIC to the registered handler.
fn handlePlic(handler: ExceptionHandler) ?void {
    const me = urd.smp.getLogicalCoreId();
    const context = plic_contexts[me];

    const source = arch.plic.claim(context);
    if (source == 0) return;
    defer arch.plic.complete(context, source);

    return handler(plic_vector_base + source);
}

/// Enable an interrupt by ID.
pub fn enableIrq(id: usize) void {
    switch (id) {
        // Timer interrupt.
        arch.timer.ppi_intid => arch.timer.enable(),
        // IPIs.
        tlb_shootdown_vector, resched_vector => arch.exception.enableSoftwareIrq(),
        // PLIC interrupts.
        else => if (id >= plic_vector_base) {
            const me = urd.smp.getLogicalCoreId();
            const source: u32 = @intCast(id - plic_vector_base);
            arch.plic.setPriority(source, 1);
            arch.plic.enable(plic_contexts[me], source);
        } else {
            @panic("Unexpected IRQ number to enable");
        },
    }
}

/// Send an IPI to all cores except the caller.
pub fn sendIpiAll(vector: u64) void {
    const self = urd.smp.getLogicalCoreId();
    for (0..num_cpus) |cpu| {
        if (cpu != self) sendIpi(cpu, vector);
    }
}

/// Send an IPI to the core of the given logical CPU ID.
pub fn sendIpi(cpu: usize, vector: u64) void {
    // Set SW IPI pending bit.
    _ = ipi_pending[cpu].fetchOr(@as(u64, 1) << @intCast(vector), .release);

    // Send IPI to the target core.
    const target = urd.smp.archCoreIdOf(cpu);
    arch.sbi.sendIpi(1, target) catch |err| {
        std.debug.panic("Failed to send IPI to CPU#{d}: {}", .{ cpu, err });
    };
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
