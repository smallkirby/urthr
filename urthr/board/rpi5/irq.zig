/// Interrupt vector.
pub const IntVector = enum(u8) {
    /// TLB shootdown IPI.
    tlb_shootdown = 0,
    /// Reschedule IPI.
    resched = 1,
    /// Local timer interrupt.
    timer = arch.timer.ppi_intid,
};

/// Exception handler called when an IRQ occurs.
var exception_handler: ?carch.ExceptionHandler = null;

/// Map and initialize the interrupt controller.
pub fn initController() urd.mem.Error!void {
    arch.gicv2.setBase(try urd.mem.phys.reserveAndRemap(
        "GIC",
        memmap.gic.start,
        memmap.gic.size(),
        null,
        .device,
    ));
    arch.gicv2.initGlobal();
}

/// Initialize the exception handling common to all CPUs.
pub fn initGlobal(f: carch.ExceptionHandler) void {
    // Set exception handler stub.
    exception_handler = f;

    // Set exception handler.
    arch.intr.setHandler(handleIrq);
}

/// Initialize GIC for the calling AP.
pub fn initLocal() urd.mem.Error!void {
    // Initialize CPU interface.
    arch.gicv2.initLocal();

    // Initialize exception handling for this CPU.
    arch.exception.initLocal();
}

/// Enable an interrupt by ID.
pub fn enable(vector: IntVector) void {
    arch.gicv2.enableIrq(@backingInt(vector));
}

/// Send an IPI to all cores except the caller.
pub fn sendIpiAll(vector: IntVector) void {
    arch.gicv2.sendSgi(@intCast(@backingInt(vector)), .all);
}

/// Send an IPI to the core of the given logical CPU ID.
pub fn sendIpi(cpu: usize, vector: IntVector) void {
    arch.gicv2.sendSgi(@intCast(@backingInt(vector)), .{
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

// =============================================================
// Imports
// =============================================================

const carch = @import("arch");
const arch = carch.impl;
const urd = @import("urthr");
const memmap = @import("memmap.zig");
const rdd = @import("dd.zig");
