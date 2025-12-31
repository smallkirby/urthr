//! Device drivers.
//!
//! Drivers don't know about the board layout and cannot rely on any board-specific information.

pub const gpio = @import("dd/gpio.zig");
pub const pl011 = @import("dd/pl011.zig");
pub const sdhc = @import("dd/sdhc.zig");

// =============================================================
// Tests
// =============================================================

test {
    _ = gpio;
    _ = pl011;
}
