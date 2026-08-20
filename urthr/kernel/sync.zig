//! Synchronization primitives.

pub const CondVar = @import("sync/CondVar.zig");
pub const Event = @import("sync/Event.zig");
pub const Mutex = @import("sync/Mutex.zig");
pub const SpinLock = @import("sync/SpinLock.zig");

/// Initialize the synchronization subsystem.
pub fn init() void {
    Event.init();
}
