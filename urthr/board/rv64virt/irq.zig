/// Interrupt vector.
pub const IntVector = enum(u8) {
    /// TLB shootdown IPI.
    tlb_shootdown = 0,
    /// Reschedule IPI.
    resched = 1,
    /// Local timer interrupt.
    timer = arch.timer.ppi_intid,

    _,
};

/// Vector number of the PLIC interrupt source 0.
///
/// This value is SW-defined.
pub const plic_vector_base: usize = 64;

/// Exception handler called when an IRQ occurs.
var exception_handler: ?carch.ExceptionHandler = null;

/// PLIC context for S-mode of each logical CPU.
///
/// Indexed by the logical CPU core ID.
var plic_contexts: [num_cpus]usize = @splat(0);
/// Pending IPI vectors of each logical CPU.
///
/// RISC-V IPI cannot send arbitrary vector numbers,
/// so this variable tracks pending IPI to multiplex IPI requests.
var ipi_pending: [num_cpus]std.atomic.Value(u64) = @splat(.init(0));

/// Map and initialize the interrupt controller.
pub fn initController() urd.mem.Error!void {
    arch.plic.setBase(try urd.mem.phys.reserveAndRemap(
        "PLIC",
        memmap.plic.start,
        memmap.plic.size(),
        null,
        .device,
    ));
}

/// Set the PLIC context of the given logical CPU.
pub fn setPlicContext(core: usize, hartid: usize) void {
    plic_contexts[core] = plicContextOf(hartid);
}

/// Calculate the PLIC context for S-mode of the given hart.
///
/// This calculation depends on the platform-specific layout of PLIC contexts.
fn plicContextOf(hartid: usize) usize {
    return hartid * 2 + 1;
}

/// Set the exception handler for IRQs.
pub fn initGlobal(f: carch.ExceptionHandler) void {
    // Set exception handler stub.
    exception_handler = f;

    // Set exception handler.
    arch.intr.setHandler(handleIrq);
}

/// Initialize interrupts for the calling AP.
pub fn initLocal() common.mem.PageAllocator.Error!void {
    // Initialize exception handling.
    arch.exception.initLocal();

    // Accept all external interrupts regardless of their priority.
    const me = arch.getCoreId();
    arch.plic.setThreshold(plicContextOf(me), 0);
    arch.exception.enableExternalIrq();

    // Unmask all maskable interrupts.
    arch.intr.unmaskAll();
}

/// Enable an interrupt by ID.
pub fn enable(vector: IntVector) void {
    switch (vector) {
        // Timer interrupt.
        .timer => arch.timer.enable(),
        // IPIs.
        .tlb_shootdown, .resched => arch.exception.enableSoftwareIrq(),
        // PLIC interrupts.
        _ => {
            const id: usize = @backingInt(vector);
            if (id < plic_vector_base) {
                @panic("Unexpected IRQ number to enable");
            }

            const me = urd.smp.getLogicalCoreId();
            const source: u32 = @intCast(id - plic_vector_base);
            arch.plic.setPriority(source, 1);
            arch.plic.enable(plic_contexts[me], source);
        },
    }
}

/// Send an IPI to all cores except the caller.
pub fn sendIpiAll(vector: IntVector) void {
    const self = urd.smp.getLogicalCoreId();
    for (0..num_cpus) |cpu| {
        if (cpu != self) sendIpi(cpu, vector);
    }
}

/// Send an IPI to the core of the given logical CPU ID.
pub fn sendIpi(cpu: usize, vector: IntVector) void {
    // Set SW IPI pending bit.
    _ = ipi_pending[cpu].fetchOr(@as(u64, 1) << @intCast(@backingInt(vector)), .release);

    // Send IPI to the target core.
    const target = urd.smp.archCoreIdOf(cpu);
    arch.sbi.sendIpi(1, target) catch |err| {
        std.debug.panic("Failed to send IPI to CPU#{d}: {}", .{ cpu, err });
    };
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
fn handleIpi(handler: carch.ExceptionHandler) ?void {
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
fn handlePlic(handler: carch.ExceptionHandler) ?void {
    const me = urd.smp.getLogicalCoreId();
    const context = plic_contexts[me];

    const source = arch.plic.claim(context);
    if (source == 0) return;
    defer arch.plic.complete(context, source);

    return handler(plic_vector_base + source);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const carch = @import("arch");
const arch = carch.impl;
const common = @import("common");
const urd = @import("urthr");
const memmap = @import("memmap.zig");
const num_cpus = @import("board.zig").num_cpus;
