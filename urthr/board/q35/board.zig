pub const memmap = @import("memmap.zig");

/// Function signature of exception handler.
///
/// Returns null if the exception cannot be handled.
pub const ExceptionHandler = *const fn (u64) ?void;

/// Number of CPU cores in the system.
pub const num_cpus = 1;

/// Exception handler called when an IRQ occurs.
var exception_handler: ?ExceptionHandler = null;

/// Boot info handed over by the bootloader.
var boot_info: BootInfo = undefined;

/// Stash the loader-provided boot info for later use.
pub fn setBoardInfo(binfo_ptr: usize) void {
    const info: *const BootInfo = @ptrFromInt(binfo_ptr);
    boot_info = info.*;
}

/// Get available memory region that we can use for booting the kernel.
pub fn getBootRegion(comptime size: usize) common.Range {
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
pub fn getKernelPaddr() usize {
    return boot_info.kphys;
}

var dram_region: [1]common.Range = undefined;

/// Get the DRAM region.
pub fn getDramRegion() []const common.Range {
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

    dram_region[0] = .{ .start = 0, .end = tail };
    return &dram_region;
}

/// Get the I/O regions that must be identity-mapped during boot.
pub inline fn getIoTempMaps() []const common.Range {
    return &.{};
}

/// Get the normal-memory regions that must be identity-mapped during boot.
pub inline fn getNormalTempMaps() []const common.Range {
    const base = @intFromPtr(boot_info.memory_map.descriptors);
    const end = base + boot_info.memory_map.buffer_size;
    return &[_]common.Range{.{
        .start = util.rounddown(base, PageAllocator.page_size),
        .end = util.roundup(end, PageAllocator.page_size),
    }};
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
pub fn remapIo(_: IoAllocator) IoAllocator.Error!void {}

/// Move the memory map provided by EFI, out of its identity mapping.
pub fn remapNormal(old: PageAllocator, new: PageAllocator) common.mem.Error!void {
    const range = getNormalTempMaps()[0];
    const page_size = PageAllocator.page_size;
    const map_size = range.size();
    const npages = util.roundup(map_size, page_size) / page_size;

    // Copy the descriptors out of the temporary identity mapping.
    const buf = try new.allocPagesV(npages);
    const src: [*]const u8 = @ptrFromInt(old.translateV(range.start));
    @memcpy(buf[0..map_size], src[0..map_size]);
    boot_info.memory_map.descriptors = @ptrCast(buf.ptr);

    // Tear down the temporary identity mapping and reclaim the physical pages.
    const as = mem.getInitAddressSpace();
    try arch.mmu.unmap4kb(
        as,
        range.start,
        npages * page_size,
        new,
    );
    for (0..npages) |i| {
        const page_ptr: [*]u8 = @ptrFromInt(range.start + i * page_size);
        new.freePagesP(page_ptr[0..page_size]);
    }
}

/// De-initialize loader resources.
pub fn deinitLoader() void {
    arch.gdt.globalInit();
}

/// Initialize peripherals.
///
/// This function is called before exceptions are enabled.
pub fn initPeripherals1() common.mem.Error!void {
    // APIC.
    {
        const lapic = try urd.mem.phys.reserveAndRemap(
            "LAPIC",
            arch.lapic.getBase(),
            0x1000,
            null,
            .device,
        );
        arch.lapic.setBase(lapic);
    }
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
pub fn getRandom(buf: []u8) void {
    if (!arch.rng.isSupported()) {
        @panic("CPU does not support RNG");
    }

    for (buf) |*byte| {
        if (arch.rng.getRandom()) |val| {
            byte.* = @truncate(val);
            break;
        }
    }
}

/// Set the exception handler for IRQs.
pub fn initIrqGlobal(f: ExceptionHandler) void {
    // Set exception handler stub.
    exception_handler = f;

    // Set exception handler.
    arch.intr.setHandler(handleIrq);

    // Disable the legacy PIC in favor of the local/IO APIC.
    arch.pic.disable();
}

/// Vector delivered by the local APIC for spurious interrupts.
const spurious_vector: u8 = 0xFF;

/// Initialize interrupts for the calling AP.
pub fn initIrqLocal() PageAllocator.Error!void {
    arch.exception.initLocal();
    arch.lapic.enable(spurious_vector);
}

/// Enable an interrupt by ID.
pub fn enableIrq(_: usize) void {
    urd.unimplemented("");
}

/// IRQ handler function.
fn handleIrq(vector: u64) ?void {
    if (exception_handler) |f| {
        return f(vector);
    } else {
        return null;
    }
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
