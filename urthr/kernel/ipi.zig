//! IPI implementation.

/// Serializes concurrent TLB shootdown operations.
var tlb_shootdown_lock: SpinLock = .{};

/// Initialize the global IPI infrastructure.
pub fn initGlobal() void {
    urd.exception.setHandler(
        board.tlb_shootdown_vector,
        handleTlbShootdown,
    ) catch {
        @panic("Failed to register TLB shootdown IPI handler.");
    };
}

/// Enable IPI infrastructure on the calling core.
pub fn initLocal() void {
    board.enableIrq(board.tlb_shootdown_vector);
}

/// Flush the TLB on every other core.
///
/// The caller is responsible for flushing its own local TLB.
pub fn tlbShootdown() void {
    if (board.num_cpus == 1) return;

    urd.sched.preemptDisable();
    defer urd.sched.preemptEnable();

    const ie = arch.intr.getMask();
    arch.intr.unmaskAll();
    defer arch.intr.setMask(ie);

    tlb_shootdown_lock.lock();
    defer tlb_shootdown_lock.unlock();

    // Send a TLB shootdown IPI to all other cores.
    board.sendIpiAll(board.tlb_shootdown_vector);

    // Wait for all other cores to acknowledge.
    urd.sync.syncAllCores();
}

/// Handler invoked when a core receives a TLB shootdown IPI.
fn handleTlbShootdown(_: urd.exception.Vector) void {
    // Flush local TLB entries.
    arch.mmu.flush();
    // Acknowledge the IPI.
    urd.sync.syncAllCores();
}

// =============================================================
// Imports
// =============================================================

const board = @import("board").impl;
const arch = @import("arch").impl;
const urd = @import("urthr");
const SpinLock = urd.sync.SpinLock;
