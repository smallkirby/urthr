//! Mutex that users can acquire in shared or exclusive mode.
//!
//! Upgrading from shared to exclusive is not supported.

const Self = @This();
const SharedLock = @This();

/// Lock protecting fields.
_guard: SpinLock = .{},
/// Number of threads holding the lock in shared mode.
_readers: usize = 0,
/// Whether the lock is held in exclusive mode.
_writer: bool = false,
/// Number of threads waiting for exclusive mode.
_writers_waiting: usize = 0,
/// Signaled when the lock is released or downgraded.
_cv: CondVar = .{},

pub const LockType = enum {
    /// Shared mode allows multiple threads to hold the lock simultaneously.
    shared,
    /// Exclusive mode allows only one thread to hold the lock.
    exclusive,
};

/// Acquire the lock in the specified mode.
///
/// If shared mode is requested, blocks while the lock is held in exclusive mode or an exclusive request is waiting.
/// If exclusive mode is requested, blocks while the lock is held by any other thread.
///
/// Even shared lock cannot be acquired multiple times by the same thread by the same thread and would deadlock.
pub fn lock(self: *Self, ltype: LockType) void {
    switch (ltype) {
        .shared => lockShared(self),
        .exclusive => lockExclusive(self),
    }
}

/// Try to acquire the lock in the specified mode without blocking.
///
/// Returns true if the lock is acquired.
pub fn tryLock(self: *Self, ltype: LockType) bool {
    const ie = self._guard.lockDisableIrq();
    defer self._guard.unlockRestoreIrq(ie);

    switch (ltype) {
        .shared => {
            if (self._writer or self._writers_waiting > 0) return false;
            self._readers += 1;
        },
        .exclusive => {
            if (self._writer or self._readers > 0) return false;
            self._writer = true;
        },
    }
    return true;
}

/// Release the lock in the specified mode.
///
/// If shared mode is requested, releases one shared hold on the lock.
/// If exclusive mode is requested, releases the exclusive hold on the lock.
pub fn unlock(self: *Self, ltype: LockType) void {
    switch (ltype) {
        .shared => unlockShared(self),
        .exclusive => unlockExclusive(self),
    }
}

/// Acquire the lock in shared mode.
///
/// Blocks while the lock is held in exclusive mode or an exclusive request is waiting.
fn lockShared(self: *Self) void {
    const ie = self._guard.lockDisableIrq();
    defer self._guard.unlockRestoreIrq(ie);

    while (self._writer or self._writers_waiting > 0) {
        self._cv.wait(&self._guard);
    }
    self._readers += 1;
}

/// Release the lock held in shared mode.
fn unlockShared(self: *Self) void {
    const ie = self._guard.lockDisableIrq();
    defer self._guard.unlockRestoreIrq(ie);

    rtt.expect(self._readers > 0);
    self._readers -= 1;
    if (self._readers == 0) {
        self._cv.broadcast();
    }
}

/// Acquire the lock in exclusive mode.
///
/// Blocks while the lock is held in any mode.
fn lockExclusive(self: *Self) void {
    const ie = self._guard.lockDisableIrq();
    defer self._guard.unlockRestoreIrq(ie);

    self._writers_waiting += 1;
    while (self._writer or self._readers > 0) {
        self._cv.wait(&self._guard);
    }
    self._writers_waiting -= 1;
    self._writer = true;
}

/// Release the lock held in exclusive mode.
fn unlockExclusive(self: *Self) void {
    const ie = self._guard.lockDisableIrq();
    defer self._guard.unlockRestoreIrq(ie);

    rtt.expect(self._writer);
    self._writer = false;
    self._cv.broadcast();
}

/// Convert the lock held in exclusive mode into shared mode without releasing it.
pub fn downgrade(self: *Self) void {
    const ie = self._guard.lockDisableIrq();
    defer self._guard.unlockRestoreIrq(ie);

    rtt.expect(self._writer);
    self._writer = false;
    self._readers += 1;
    self._cv.broadcast();
}

/// Wrapper of shared lock to track the mode held by the owner.
///
/// A lock managed through this holder must not be operated directly.
pub const Holder = struct {
    /// Serializes operations of this holder.
    _mutex: Mutex = .{},
    /// Mode in which the lock is currently held by the holder.
    _held: ?LockType = null,

    /// Acquire the lock in the specified mode, converting the mode already held by this holder.
    pub fn lock(self: *Holder, sl: *SharedLock, ltype: LockType) void {
        self._mutex.lock();
        defer self._mutex.unlock();

        if (self.convert(sl, ltype)) {
            return;
        }
        sl.lock(ltype);
        self._held = ltype;
    }

    /// Try to acquire the lock in the specified mode without blocking on the lock.
    ///
    /// Returns true if the lock is acquired.
    pub fn tryLock(self: *Holder, sl: *SharedLock, ltype: LockType) bool {
        self._mutex.lock();
        defer self._mutex.unlock();

        if (self.convert(sl, ltype)) {
            return true;
        }
        if (!sl.tryLock(ltype)) {
            return false;
        }
        self._held = ltype;
        return true;
    }

    /// Release the lock held by this holder.
    ///
    /// Safe to call even if no lock is held.
    pub fn unlock(self: *Holder, sl: *SharedLock) void {
        self._mutex.lock();
        defer self._mutex.unlock();

        if (self._held) |held| {
            sl.unlock(held);
            self._held = null;
        }
    }

    /// Convert the mode held by this holder.
    ///
    /// Returns true if the holder now holds the specified mode of lock.
    /// Otherwise, the holder holds nothing and the caller must acquire the lock.
    fn convert(self: *Holder, sl: *SharedLock, ltype: LockType) bool {
        const held = self._held orelse {
            return false;
        };
        if (held == ltype) {
            return true;
        }

        if (held == .exclusive) {
            sl.downgrade();
            self._held = .shared;
            return true;
        } else {
            sl.unlock(held);
            self._held = null;
            return false;
        }
    }
};

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const rtt = common.rtt;
const CondVar = @import("CondVar.zig");
const Mutex = @import("Mutex.zig");
const SpinLock = @import("SpinLock.zig");
