//! Synchronization primitives.

pub const CondVar = @import("sync/CondVar.zig");
pub const Event = @import("sync/Event.zig");

/// Initialize the synchronization subsystem.
pub fn init() void {
    Event.init();
}
