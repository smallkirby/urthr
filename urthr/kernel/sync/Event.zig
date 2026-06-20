//! Synchronization primitive for notifying threads.

const Self = @This();

/// Lock protecting the event state.
lock: SpinLock = .{},
/// List of waiters waiting on this event.
waiters: Waiter.List = .{},
/// Pending signal.
///
/// Set when the event is signaled but no thread was waiting.
signaled: bool = false,

/// Block until this event is signaled.
///
/// Returns immediately if the event already has a pending signal.
pub fn wait(self: *Self) void {
    const ie = self.lock.lockDisableIrq();

    // If the event is already signaled, return immediately.
    if (self.signaled) {
        self.signaled = false;
        self.lock.unlockRestoreIrq(ie);
        return;
    }

    var woken = false;
    var waiter = Waiter{
        .thread = sched.getCurrent(),
        .woken = &woken,
    };
    self.waiters.append(&waiter);

    // Block the current thread.
    // The lock is released atomically by the scheduler.
    sched.blockCurrent(&self.lock);

    // Restore IRQ state.
    arch.intr.setMask(ie);
}

/// Maximum number of events `waitAny()` can wait on at once.
pub const max_multiwait = 8;

/// Block until any of the given events is signaled.
///
/// Returns the event that was consumed.
/// Returns immediately if any event already has a pending signal.
///
/// Exactly one event's signal is consumed.
/// Signals on the other events remain pending.
///
/// Must NOT be called from IRQ context.
pub fn waitAny(events: []const *Self) *Self {
    rtt.expect(events.len > 0);
    rtt.expect(events.len <= max_multiwait);
    const current = sched.getCurrent();

    var entries: [max_multiwait]Waiter = undefined;
    var woken = false;
    var fired: usize = undefined;
    var registered: usize = 0;

    for (events, 0..) |ev, i| {
        const entry = &entries[i];
        const ie = ev.lock.lockDisableIrq();
        defer ev.lock.unlockRestoreIrq(ie);

        entry.* = .{
            .thread = current,
            .woken = &woken,
            .fired = &fired,
            .index = i,
        };

        if (ev.signaled) {
            ev.signaled = false;
            woken = true;
            fired = i;
            break;
        }

        ev.waiters.append(entry);
        registered += 1;
    }

    // Block the current thread.
    sched.blockCurrentCheckWoken(&woken);

    // Remove entries from the waiters list of each event.
    for (events[0..registered], 0..) |ev, i| {
        const entry = &entries[i];
        if (!entry.removed) {
            const ie = ev.lock.lockDisableIrq();
            defer ev.lock.unlockRestoreIrq(ie);

            if (!entry.removed) ev.waiters.remove(entry);
        }
    }

    return events[fired];
}

/// Wake one waiter.
///
/// If no thread is waiting, the signal is saved for the next waiter.
/// Returns true if a live waiter was woken.
pub fn wake(self: *Self) bool {
    const ie = self.lock.lockDisableIrq();
    defer self.lock.unlockRestoreIrq(ie);

    while (self.waiters.popFirst()) |waiter| {
        waiter.removed = true;

        // Wake the first live waiter.
        if (!waiter.woken.*) {
            waiter.woken.* = true;
            if (waiter.fired) |fired|
                fired.* = waiter.index;

            sched.wake(waiter.thread);
            return true;
        }
    } else {
        // No live waiter was woken.
        self.signaled = true;
        return false;
    }
}

/// Wake all waiters.
///
/// If no live waiter is woken, the signal is remembered as pending.
pub fn wakeAll(self: *Self) void {
    const ie = self.lock.lockDisableIrq();
    defer self.lock.unlockRestoreIrq(ie);

    var woke_any = false;
    while (self.waiters.popFirst()) |waiter| {
        waiter.removed = true;

        // Wake the live waiters.
        if (!waiter.woken.*) {
            waiter.woken.* = true;
            if (waiter.fired) |fired|
                fired.* = waiter.index;

            sched.wake(waiter.thread);
            woke_any = true;
        }
    }

    if (!woke_any) {
        // No live waiter was woken.
        self.signaled = true;
    }
}

// =============================================================
// Internals
// =============================================================

/// Single waiter waiting on an event.
const Waiter = struct {
    /// Waiting thread.
    thread: *Thread,
    /// Indicates if the waiter has been woken.
    ///
    /// On multi-wait, this is shared between all events.
    /// Can be already true when an event is signaled, if other events are signaled beforehand.
    woken: *bool,
    /// On multi-wait, set to the index of the event that was signaled.
    fired: ?*usize = null,
    /// Index of this waiter within the `waitAny` events slice.
    index: usize = 0,
    /// Indicates if the waiter has been removed from the waiters list.
    ///
    /// On multi-wait, `removed` can be false while `woken` is true, if another event was signaled first.
    /// This field is used track the remaining events to unregister.
    removed: bool = false,
    /// List head.
    ///
    /// Constructs a list of threads waiting on the same event.
    head: List.Head = .{},

    const List = typing.InlineDoublyLinkedList(Waiter, "head");
};

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const typing = common.typing;
const rtt = common.rtt;
const arch = @import("arch").impl;
const urd = @import("urthr");
const sched = urd.sched;
const SpinLock = urd.SpinLock;
const Thread = urd.task.thread.Thread;
