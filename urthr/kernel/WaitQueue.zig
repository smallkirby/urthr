//! Synchronization primitive for blocking threads until a condition is met.

const Self = @This();

/// List of threads waiting on this queue.
waiters: ThreadList = .{},

/// Wake one thread from the wait queue.
///
/// Moves the first waiting thread to the scheduler's ready queue.
///
/// Returns true if a thread was woken up.
pub fn wake(self: *Self) bool {
    const th = self.waiters.popFirst() orelse {
        // No waiters to wake.
        return false;
    };

    sched.enqueue(th);
    sched.markNeedResched();

    return true;
}

/// Block the current thread on this wait queue.
///
/// The caller must hold the protecting SpinLock with IRQs disabled.
/// The lock is released before sleeping and re-acquired after waking.
///
/// This must NOT be called from IRQ context.
pub fn wait(self: *Self, spin: *SpinLock) void {
    rtt.expect(spin.isLocked());

    self.waiters.append(sched.getCurrent());

    // Release the protecting lock and switch to another thread.
    sched.blockCurrent(spin);

    // Re-acquire the lock with IRQs disabled.
    _ = spin.lockDisableIrq();
}

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const rtt = common.rtt;
const urd = @import("urthr");
const sched = urd.sched;
const SpinLock = urd.SpinLock;
const thread = urd.thread;
const Thread = thread.Thread;
const ThreadList = thread.ThreadList;
