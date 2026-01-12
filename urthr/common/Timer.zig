const Self = @This();

vtable: Vtable,

/// Type-erased context pointer.
_ctx: *anyopaque,
/// Start time of the timer.
_start: u64 = undefined,
/// Duration of the timer in microseconds.
_duration: u64 = undefined,

pub const TimeSlice = struct {
    /// Duration of the time in microseconds.
    _us: u64,

    /// Create a time slice representing the given microseconds.
    pub fn us(value: u64) TimeSlice {
        return .{ ._us = value * 1 };
    }

    /// Create a time slice representing the given milliseconds.
    pub fn ms(value: u64) TimeSlice {
        return .{ ._us = value * 1_000 };
    }

    /// Create a time slice representing the given seconds.
    pub fn sec(value: u64) TimeSlice {
        return .{ ._us = value * 1_000_000 };
    }
};

pub const Vtable = struct {
    /// Get the current value of the timer in microseconds.
    getCurrent: *const fn (ctx: *anyopaque) u64,
};

/// Start the timer for the given duration in microseconds.
pub fn start(self: *Self, duration: TimeSlice) void {
    self._start = self.vtable.getCurrent(self._ctx);
    self._duration = duration._us;
}

/// Check if the timer has expired.
pub fn expired(self: *Self) bool {
    const now = self.vtable.getCurrent(self._ctx);
    return now - self._start >= self._duration;
}
