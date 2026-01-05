const Self = @This();

vtable: Vtable,

/// Type-erased context pointer.
_ctx: *anyopaque,
/// Start time of the timer.
_start: u64 = undefined,
/// Duration of the timer in microseconds.
_duration: u64 = undefined,

pub const Vtable = struct {
    /// Get the current value of the timer in microseconds.
    getCurrent: *const fn (ctx: *anyopaque) u64,
};

/// Start the timer for the given duration in microseconds.
pub fn start(self: *Self, duration_us: u64) void {
    self._start = self.vtable.getCurrent(self._ctx);
    self._duration = duration_us;
}

/// Check if the timer has expired.
pub fn expired(self: *Self) bool {
    const now = self.vtable.getCurrent(self._ctx);
    return now - self._start >= self._duration;
}
