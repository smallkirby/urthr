pub const memmap = @import("memmap.zig");

/// Function signature of exception handler.
///
/// Returns null if the exception cannot be handled.
pub const ExceptionHandler = *const fn (u64) ?void;

/// Number of CPU cores in the system.
pub const num_cpus = 1;

/// Exception handler called when an IRQ occurs.
var exception_handler: ?ExceptionHandler = null;

/// Get available memory region that we can use for booting the kernel.
pub fn getBootRegion(comptime size: usize, binfo_ptr: anytype) common.Range {
    const boot_info: *const BootInfo = @ptrFromInt(binfo_ptr);
    const map = boot_info.memory_map;

    const MemoryDescriptorIterator = BootInfo.MemoryDescriptorIterator;
    const efi_page_size = 4096;
    var desc_iter = MemoryDescriptorIterator.new(map);
    var desc = desc_iter.next();
    while (desc) |d| : (desc = desc_iter.next()) {
        if (d.type != .conventional_memory) {
            continue;
        }
        if (d.number_of_pages * efi_page_size < size) {
            continue;
        }

        return .{
            .start = d.physical_start,
            .end = d.physical_start + size,
        };
    }

    @panic("No available memory region found.");
}

/// Get the physical address kernel was loaded at.
pub fn getKernelPaddr(binfo_ptr: usize) usize {
    const boot_info: *const BootInfo = @ptrFromInt(binfo_ptr);
    return boot_info.kphys;
}

/// Get the DRAM region.
pub fn getDramRegion(binfo_ptr: usize) []const common.Range {
    const boot_info: *const BootInfo = @ptrFromInt(binfo_ptr);
    const map = boot_info.memory_map;

    const MemoryDescriptorIterator = BootInfo.MemoryDescriptorIterator;
    const efi_page_size = 4096;

    // Find the tail region except reserved memory.
    var tail: usize = 0;
    var desc_iter = MemoryDescriptorIterator.new(map);
    var desc = desc_iter.next();
    while (desc) |d| : (desc = desc_iter.next()) {
        if (d.type == .reserved_memory_type) {
            continue;
        }

        tail = @max(tail, d.physical_start + d.number_of_pages * efi_page_size);
    }

    return &[_]common.Range{.{ .start = 0, .end = tail }};
}

/// Get the regions that must be identity-mapped during boot.
pub inline fn getTempMaps() []const common.Range {
    return &.{};
}

/// Early board initialization.
///
/// Sets up essential peripherals like UART.
///
/// Expects all virtual address range is identity-mapped.
pub fn boot() void {
    dd.uart16550.setBase(0x3F8);
    dd.uart16550.init(1_843_200, 115_200); // 1.8432 MHz, 115200 bps
}

/// Map new I/O memory regions.
pub fn remap(_: IoAllocator) IoAllocator.Error!void {}

/// De-initialize loader resources.
pub fn deinitLoader() void {
    urd.unimplemented("");
}

/// Initialize peripherals.
///
/// This function is called before exceptions are enabled.
pub fn initPeripherals1() common.mem.Error!void {
    urd.unimplemented("");
}

/// Initialize peripherals phase 2.
///
/// This function is called after exceptions are enabled.
pub fn initPeripherals2() urd.mem.Error!void {
    urd.unimplemented("");
}

/// Initialize peripherals.
///
/// This function is called after initial task is spawned.
/// This function can spawn new threads.
pub fn initPeripherals3() common.mem.Error!void {
    urd.unimplemented("");
}

/// Prepare for waking up secondary cores.
pub fn prepareSubcoreWakeup() urd.mem.Error!void {
    urd.unimplemented("");
}

/// De-initialize resources used for waking up secondary cores.
pub fn deinitSubcoreWakeup() void {
    urd.unimplemented("");
}

/// Wakeup a secondary core.
///
/// This function returns before the core is actually awake.
/// The caller should wait for the core to be awake.
///
/// - core: Core number to wake up.
/// - entry: Virtual address of the entry point.
/// - stack: Virtual address of the stack pointer.
pub fn wakeSubcore(_: usize, _: usize, _: usize) urd.mem.Error!void {
    urd.unimplemented("");
}

/// Fill the given buffer with random data.
pub fn getRandom(_: []u8) void {
    urd.unimplemented("");
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
    urd.unimplemented("");
}

/// Enable an interrupt by ID.
pub fn enableIrq(_: usize) void {
    urd.unimplemented("");
}

/// IRQ handler function.
fn handleIrq() ?void {
    urd.unimplemented("handleIrq");
}

/// Get the block device interface.
pub fn getBlockDevice() ?common.block.Device {
    urd.unimplemented("");
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
pub fn reset(_: u8) void {
    urd.unimplemented("");
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
const log = std.log.scoped(.q35);
const arch = @import("arch").impl;
const common = @import("common");
const BootInfo = @import("boot").BootInfo;
const rtt = common.rtt;
const util = common.util;
const Console = common.Console;
const IoAllocator = common.mem.IoAllocator;
const PageAllocator = common.mem.PageAllocator;
const Pair = common.Pair;
const urd = @import("urthr");
const mem = urd.mem;
const dd = @import("dd");
