//! Kernel input subsystem.

pub const Device = @import("input/Device.zig");
pub const Handler = @import("input/Handler.zig");
pub const keymap = @import("input/keymap.zig");
pub const ldisc = @import("input/ldisc.zig");

/// Initialize the input subsystem and register the built-in handlers.
pub fn init() Handler.Error!void {
    try Handler.register(ttyhandler.handler);
}

test {
    _ = keymap;
}

// =============================================================
// Imports
// =============================================================

const ttyhandler = @import("input/ttyhandler.zig");
