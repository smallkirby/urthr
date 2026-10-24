//! Real-time interval timer.

const Self = @This();

/// Timer queued while the interval timer is armed.
timer: Timer = .{
    .deadline_ns = 0,
    .callback = fire,
    .fired = true,
},

/// Setting of an interval timer.
pub const Value = struct {
    /// Time remaining until the next expiration.
    ///
    /// Zero if disarmed.
    value_ns: u64,
    /// Reload interval in nanoseconds for periodic expirations.
    ///
    /// Zero for a one-shot timer.
    interval_ns: u64,
};

/// Arm or disarm the interval timer.
///
/// If `value_ns` is zero, the timer is disarmed.
///
/// Returns the old setting that was replaced.
pub fn set(self: *Self, value_ns: u64, interval_ns: u64) Value {
    const now = time.getCurrentTimestamp();
    const timer = &self.timer;

    var old: Value = .{ .value_ns = 0, .interval_ns = 0 };
    if (time.cancelTimer(timer)) old = .{
        .value_ns = timer.deadline_ns -| now,
        .interval_ns = timer.interval_ns,
    };

    if (value_ns != 0) {
        timer.deadline_ns = now + value_ns;
        timer.interval_ns = interval_ns;
        time.scheduleTimer(timer);
    }

    return old;
}

/// Disarm the interval timer.
pub fn cancel(self: *Self) void {
    _ = time.cancelTimer(&self.timer);
}

/// Deliver a signal to the thread whose interval timer has expired.
fn fire(timer: *Timer) void {
    const self: *Self = @fieldParentPtr("timer", timer);
    const thread: *Thread = @fieldParentPtr("itimer", self);
    urd.task.signal.pushTo(thread, .alarm);
}

// =============================================================
// Imports
// =============================================================

const urd = @import("urthr");
const time = urd.time;
const Timer = time.Timer;
const Thread = urd.task.thread.Thread;
