//! Synchronization primitive for blocking threads until a condition is met.

const Self = @This();

/// List of threads blocked on this condition variable.
waiters: ThreadList = .{},

/// Wake one waiting thread.
///
/// The caller must hold the protecting lock.
///
/// NOP if there are no waiters.
pub fn signal(self: *Self) void {
    if (self.waiters.popFirst()) |th| {
        sched.enqueue(th);
        sched.markNeedResched();
    }
}

/// Block the current thread on this wait queue.
///
/// The caller must hold the protecting lock with IRQs disabled.
/// The lock is released before sleeping and re-acquired after waking.
///
/// This must NOT be called from IRQ context.
pub fn wait(self: *Self, lock: *SpinLock) void {
    rtt.expect(lock.isLocked());

    self.waiters.append(sched.getCurrent());

    // Release the protecting lock and switch to another thread.
    sched.blockCurrent(lock);

    // Re-acquire the lock with IRQs disabled.
    _ = lock.lockDisableIrq();
}

/// Wake all waiting threads.
///
/// The caller must hold the protecting lock.
///
/// NOP if there are no waiters.
pub fn broadcast(self: *Self) void {
    var woke = false;
    while (self.waiters.popFirst()) |th| {
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
const urd = @import("urthr");
const sched = urd.sched;
const SpinLock = urd.SpinLock;
const thread = urd.task.thread;
const ThreadList = thread.ThreadList;
