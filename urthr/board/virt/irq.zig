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
pub fn initController() common.mem.Error!void {
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

/// Set the exception handler for IRQs.
pub fn initGlobal(f: carch.ExceptionHandler) void {
    // Set exception handler stub.
    exception_handler = f;

    // Set exception handler.
    arch.intr.setHandler(handleIrq);
}

/// Initialize GIC for the calling AP.
pub fn initLocal() common.mem.PageAllocator.Error!void {
    // Initialize CPU interface.
    try arch.gicv3.initLocal(urd.mem.page);

    // Initialize exception handling for this CPU.
    arch.exception.initLocal();
}

/// Enable an interrupt by ID.
pub fn enable(vector: IntVector) void {
    arch.gicv3.enableIrq(@backingInt(vector));
}

/// Send an IPI to all cores except the caller.
pub fn sendIpiAll(vector: IntVector) void {
    arch.gicv3.sendSgi(@intCast(@backingInt(vector)), .all);
}

/// Send an IPI to the core of the given logical CPU ID.
pub fn sendIpi(cpu: usize, vector: IntVector) void {
    arch.gicv3.sendSgi(@intCast(@backingInt(vector)), .{
        .target = &.{@intCast(cpu)},
    });
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

// =============================================================
// Imports
// =============================================================

const carch = @import("arch");
const arch = carch.impl;
const common = @import("common");
const urd = @import("urthr");
const memmap = @import("memmap.zig");
