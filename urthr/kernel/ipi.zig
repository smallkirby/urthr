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
/// Cores that have not yet acknowledged the current shootdown.
var tlb_shootdown_pending: std.atomic.Value(u64) = .init(0);

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
///
/// Blocks until every other core has acknowledged.
pub fn tlbShootdown(range: ?Range) void {
    if (board.num_cpus == 1) return;

    urd.sched.preemptDisable();
    defer urd.sched.preemptEnable();

    const ie = arch.intr.getMask();
    arch.intr.unmaskAll();
    defer arch.intr.setMask(ie);

    tlb_shootdown_lock.lock();
    defer tlb_shootdown_lock.unlock();

    const others = ((@as(u64, 1) << board.num_cpus) - 1) &
        ~(@as(u64, 1) << @intCast(urd.smp.getLogicalCoreId()));

    tlb_shootdown_range = range;
    defer tlb_shootdown_range = null;
    tlb_shootdown_pending.store(others, .release);

    // Send a TLB shootdown IPI to all other cores.
    board.sendIpiAll(board.tlb_shootdown_vector);
    while (tlb_shootdown_pending.load(.acquire) != 0) {
        std.atomic.spinLoopHint();
    }
}

/// Handler invoked when a core receives a TLB shootdown IPI.
fn handleTlbShootdown(_: urd.exception.Vector) void {
    const bit = @as(u64, 1) << @intCast(urd.smp.getLogicalCoreId());
    if (tlb_shootdown_pending.load(.acquire) & bit == 0) return;

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

    // Acknowledge the request.
    _ = tlb_shootdown_pending.fetchAnd(~bit, .release);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const board = @import("board").impl;
const arch = @import("arch").impl;
const urd = @import("urthr");
const SpinLock = urd.sync.SpinLock;
