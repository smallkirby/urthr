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

/// Block until this event is signaled or the deadline expires.
///
/// Returns true if the event was signaled, false if the deadline expired.
/// Returns immediately if the event already has a pending signal.
///
/// If the given deadline is null, blocks indefinitely.
///
/// Must NOT be called from IRQ context.
pub fn wait(self: *Self, deadline_ns: ?u64) bool {
    return waitAny(&.{self}, deadline_ns) != null;
}

/// Maximum number of events `waitAny()` can wait on at once.
pub const max_multiwait = 8;

/// Block until any of the given events is signaled or the deadline expires.
///
/// Returns the event that was consumed, or null if the deadline expired.
/// Returns immediately if any event already has a pending signal.
///
/// If the given deadline is null, blocks indefinitely.
///
/// Exactly one event's signal is consumed.
/// Signals on the other events remain pending.
///
/// Must NOT be called from IRQ context.
pub fn waitAny(events: []const *Self, deadline_ns: ?u64) ?*Self {
    if (deadline_ns) |dl| {
        rtt.expect(events.len < max_multiwait);

        var timer: TimerEvent = .{ .deadline = .{
            .deadline_ns = dl,
            .callback = wakeTimerEvent,
        } };
        time.scheduleDeadline(&timer.deadline);
        defer time.cancelDeadline(&timer.deadline);

        var all_events: [max_multiwait]*Self = undefined;
        @memcpy(all_events[0..events.len], events);
        all_events[events.len] = &timer.event;

        const fired = waitAnyImpl(all_events[0 .. events.len + 1]);
        return if (fired == &timer.event) null else fired;
    } else {
        return waitAnyImpl(events);
    }
}

/// Event paired with its deadline.
const TimerEvent = struct {
    event: Self = .{},
    deadline: time.Deadline = undefined,
};

/// Wake the timer event paired with the given deadline.
fn wakeTimerEvent(entry: *time.Deadline) void {
    const timer: *TimerEvent = @fieldParentPtr("deadline", entry);
    _ = timer.event.wake();
}

/// Block until any of the given events is signaled.
fn waitAnyImpl(events: []const *Self) *Self {
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

const std = @import("std");
const common = @import("common");
const typing = common.typing;
const rtt = common.rtt;
const arch = @import("arch").impl;
const urd = @import("urthr");
const sched = urd.sched;
const time = urd.time;
const Thread = urd.task.thread.Thread;
const SpinLock = @import("SpinLock.zig");
