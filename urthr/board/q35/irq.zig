/// Interrupt vector.
pub const IntVector = enum(u8) {
    /// Local timer interrupt.
    timer = arch.timer.ppi_intid,
    /// xHC interrupt.
    xhci = 0x40,
    /// virtio-net interrupt.
    virtio_net = 0x41,
    /// virtio-blk interrupt.
    virtio_blk = 0x42,
    /// virtio-gpu interrupt.
    virtio_gpu = 0x43,
    /// TLB shootdown IPI.
    tlb_shootdown = 0x60,
    /// Reschedule IPI.
    resched = 0x61,
};

/// Exception handler called when an IRQ occurs.
var exception_handler: ?carch.ExceptionHandler = null;

/// Map and initialize the interrupt controller.
pub fn initController() urd.mem.Error!void {
    const lapic = try urd.mem.phys.reserveAndRemap(
        "LAPIC",
        arch.lapic.getBase(),
        0x1000,
        null,
        .device,
    );
    arch.lapic.setBase(lapic);
}

/// Set the exception handler for IRQs.
pub fn initGlobal(f: carch.ExceptionHandler) void {
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
pub fn initLocal() common.mem.PageAllocator.Error!void {
    arch.exception.initLocal();
    arch.lapic.enable(spurious_vector);

    // Unmask all maskable interrupts.
    arch.intr.unmaskAll();
}

/// Enable an interrupt by ID.
///
/// TODO: supports I/O APIC.
pub fn enable(_: IntVector) void {}

/// Send an IPI to all cores except the caller.
pub fn sendIpiAll(vector: IntVector) void {
    arch.lapic.sendIpiAllExclSelf(@backingInt(vector));
}

/// Send an IPI to the core of the given logical CPU ID.
pub fn sendIpi(cpu: usize, vector: IntVector) void {
    arch.lapic.sendIpi(
        @intCast(urd.smp.archCoreIdOf(cpu)),
        @backingInt(vector),
    );
}

/// IRQ handler function.
fn handleIrq(vector: u64) ?void {
    if (exception_handler) |f| {
        const ret = f(vector);

        arch.lapic.eoi();

        if (urd.sched.shouldReschedule()) {
            urd.sched.reschedule();
        }

        return ret;
    } else {
        arch.lapic.eoi();
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
