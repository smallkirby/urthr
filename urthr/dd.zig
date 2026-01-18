//! Device drivers.
//!
//! Drivers don't know about the board layout and cannot rely on any board-specific information.

pub const gpio = @import("dd/gpio.zig");
pub const net = @import("dd/net.zig");
pub const pci = @import("dd/pci.zig");
pub const pl011 = @import("dd/pl011.zig");
pub const sdhc = @import("dd/sdhc.zig");
pub const virtio = @import("dd/virtio.zig");
pub const VirtioBlk = @import("dd/VirtioBlk.zig");

// =============================================================
// Tests
// =============================================================

test {
    _ = gpio;
    _ = pl011;
}
