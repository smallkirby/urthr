//! Synchronization primitives.

pub const CondVar = @import("sync/CondVar.zig");
pub const Event = @import("sync/Event.zig");
pub const Mutex = @import("sync/Mutex.zig");
pub const SpinLock = @import("sync/SpinLock.zig");

/// Initialize the synchronization subsystem.
pub fn init() void {
    Event.init();
}

/// Block until every core has reached this point.
pub fn syncAllCores() void {
    const ie = arch.intr.maskAll();
    defer arch.intr.setMask(ie);

    // Sense-reversing barrier.
    const S = struct {
        /// Number of cores that have reached the current round.
        var count: std.atomic.Value(usize) = .init(0);
        /// Shared sense.
        var global_sense: std.atomic.Value(bool) = .init(false);
        /// Core-local sense.
        var local_sense: [board.num_cpus]bool = [_]bool{false} ** board.num_cpus;
    };

    const sense = &S.local_sense[smp.getLogicalCoreId()];
    const mine = !sense.*;
    sense.* = mine;

    if (S.count.fetchAdd(1, .acq_rel) + 1 == board.num_cpus) {
        S.count.store(0, .release);
        S.global_sense.store(mine, .release);
    } else while (S.global_sense.load(.acquire) != mine) {
        std.atomic.spinLoopHint();
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const board = @import("board").impl;
const urd = @import("urthr");
const smp = urd.smp;
const arch = @import("arch").impl;
