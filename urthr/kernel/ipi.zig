//! IPI implementation.

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

// =============================================================
// TLB shootdown

/// Serializes concurrent TLB shootdown operations.
var tlb_shootdown_lock: SpinLock = .{};
/// Range of the currently processing TLB shootdown.
var tlb_shootdown_range: ?Range = null;

/// Virtual address range to invalidate.
const Range = struct {
    /// Virtual address.
    addr: usize,
    /// Length in bytes.
    len: usize,
};

/// Flush the TLB on every other core.
///
/// The caller is responsible for flushing its own local TLB.
pub fn tlbShootdown(range: ?Range) void {
    if (board.num_cpus == 1) return;

    urd.sched.preemptDisable();
    defer urd.sched.preemptEnable();

    const ie = arch.intr.getMask();
    arch.intr.unmaskAll();
    defer arch.intr.setMask(ie);

    tlb_shootdown_lock.lock();
    defer tlb_shootdown_lock.unlock();

    tlb_shootdown_range = range;
    defer tlb_shootdown_range = null;

    // Send a TLB shootdown IPI to all other cores.
    board.sendIpiAll(board.tlb_shootdown_vector);

    // Wait for all other cores to acknowledge.
    urd.sync.syncAllCores();
}

/// Handler invoked when a core receives a TLB shootdown IPI.
fn handleTlbShootdown(_: urd.exception.Vector) void {
    // Invalidate local TLB entries.
    if (tlb_shootdown_range) |range| {
        arch.mmu.tlb.invalidateRange(
            undefined,
            range.addr,
            range.len,
            .local,
        );
    } else {
        arch.mmu.tlb.invalidateAll(
            undefined,
            .local,
        );
    }
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
