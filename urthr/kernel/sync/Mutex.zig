//! Mutex primitive.

const Self = @This();

/// Lock protecting fields.
_guard: SpinLock = .{},
/// Whether the mutex is currently held.
_locked: bool = false,
/// Signaled when the mutex is released.
_cv: CondVar = .{},

/// Acquire the mutex, blocking the current thread while it is held by another thread.
pub fn lock(self: *Self) void {
    const ie = self._guard.lockDisableIrq();
    defer self._guard.unlockRestoreIrq(ie);

    while (self._locked) {
        self._cv.wait(&self._guard);
    }
    self._locked = true;
}

/// Release the mutex.
pub fn unlock(self: *Self) void {
    const ie = self._guard.lockDisableIrq();
    defer self._guard.unlockRestoreIrq(ie);

    self._locked = false;
    self._cv.signal();
}

/// Check if the mutex is currently held by any thread.
///
/// Note that this does not guarantee that the mutex will remain unlocked after this function.
/// Even if this mutex is locked by another thread, this function returns `true`.
pub fn isLocked(self: *Self) bool {
    return self._locked;
}

// =============================================================
// Imports
// =============================================================

const CondVar = @import("CondVar.zig");
const SpinLock = @import("SpinLock.zig");
