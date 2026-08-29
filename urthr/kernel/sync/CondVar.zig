//! Synchronization primitive for blocking threads until a condition is met.

const Self = @This();

/// Protects the wait list.
_guard: SpinLock = .{},
/// List of threads blocked on this condition variable.
_waiters: ThreadList = .{},

/// Wake one waiting thread.
///
/// NOP if there are no waiters.
pub fn signal(self: *Self) void {
    const ie = self._guard.lockDisableIrq();
    defer self._guard.unlockRestoreIrq(ie);

    if (self._waiters.popFirst()) |th| {
        sched.enqueue(th);
        sched.markNeedResched();
    }
}

/// Block the current thread until it is signalled.
///
/// The caller must hold the protecting lock on entry.
/// The lock is re-acquired before returning.
///
/// This must NOT be called from IRQ context.
pub fn wait(self: *Self, lock: anytype) void {
    rtt.expect(lock.isLocked());

    const ie = self._guard.lockDisableIrq();
    self._waiters.append(sched.getCurrent());

    // Release the protecting lock and switch to another thread.
    lock.unlock();
    sched.blockCurrent(&self._guard);

    // Re-acquire the protecting lock and restore the caller's interrupt mask.
    lock.lock();
    arch.intr.setMask(ie);
}

/// Wake all waiting threads.
///
/// NOP if there are no waiters.
pub fn broadcast(self: *Self) void {
    const ie = self._guard.lockDisableIrq();
    defer self._guard.unlockRestoreIrq(ie);

    var woke = false;
    while (self._waiters.popFirst()) |th| {
        sched.enqueue(th);
        woke = true;
    }
    if (woke) sched.markNeedResched();
}

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const rtt = common.rtt;
const arch = @import("arch").impl;
const urd = @import("urthr");
const sched = urd.sched;
const thread = urd.task.thread;
const ThreadList = thread.ThreadList;
const SpinLock = @import("SpinLock.zig");
