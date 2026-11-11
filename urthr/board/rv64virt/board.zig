pub const memmap = @import("memmap.zig");
pub const sync = @import("sync.zig");

/// Function signature of exception handler.
///
/// Returns null if the exception cannot be handled.
pub const ExceptionHandler = *const fn (u64) ?void;

/// Number of CPU cores in the system.
pub const num_cpus = 1; // TODO

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
    dd.uart16550.setBase(memmap.uart.start);
}

/// Map new I/O memory regions.
pub fn remapIo(_: IoAllocator) IoAllocator.Error!void {
    @panic(todo);
}

/// Move new normal memory regions.
pub fn remapNormal(_: PageAllocator, _: PageAllocator) common.mem.Error!void {}

/// De-initialize loader resources.
pub fn deinitLoader() void {}

/// Initialize peripherals.
///
/// This function is called before exceptions are enabled.
pub fn initPeripherals1() common.mem.Error!void {
    @panic(todo);
}

/// Initialize peripherals phase 2.
///
/// This function is called after exceptions are enabled.
pub fn initPeripherals2() urd.mem.Error!void {
    @panic(todo);
}

/// Initialize peripherals.
///
/// This function is called after initial task is spawned.
/// This function can spawn new threads.
pub fn initPeripherals3() common.mem.Error!void {
    @panic(todo);
}

/// Prepare for waking up secondary cores.
pub fn prepareSubcoreWakeup() urd.mem.Error!void {
    @panic("TODO: SMP is not supported on rv64virt yet.");
}

/// De-initialize resources used for waking up secondary cores.
pub fn deinitSubcoreWakeup() void {
    @panic("TODO: SMP is not supported on rv64virt yet.");
}

/// Wakeup a secondary core.
pub fn wakeSubcore(_: usize, _: usize, _: usize) urd.mem.Error!void {
    @panic("TODO: SMP is not supported on rv64virt yet.");
}

/// Fill the given buffer with random data.
pub fn getRandom(_: []u8) void {
    @panic(todo);
}

/// Set the exception handler for IRQs.
pub fn initIrqGlobal(_: ExceptionHandler) void {}

/// Initialize interrupts for the calling AP.
pub fn initIrqLocal() common.mem.PageAllocator.Error!void {
    @panic(todo);
}

/// Enable an interrupt by ID.
pub fn enableIrq(_: usize) void {
    @panic(todo);
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

const arch = @import("arch").impl;
const common = @import("common");
const dd = @import("dd");
const Console = common.Console;
const IoAllocator = common.mem.IoAllocator;
const PageAllocator = common.mem.PageAllocator;
const urd = @import("urthr");
