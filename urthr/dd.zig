//! Device drivers.
//!
//! Drivers don't know about the board layout and cannot rely on any board-specific information.

pub const fake_rng = @import("dd/fake_rng.zig");
pub const net = @import("dd/net.zig");
pub const pci = @import("dd/pci.zig");
pub const pl011 = @import("dd/pl011.zig");
pub const sdhc = @import("dd/sdhc.zig");
pub const uart16550 = @import("dd/uart16550.zig");
pub const usb = @import("dd/usb.zig");
pub const virtio = @import("dd/virtio.zig");
pub const VirtioBlk = @import("dd/VirtioBlk.zig");
pub const VirtioRng = @import("dd/VirtioRng.zig");

// =============================================================
// Tests
// =============================================================

test {
    _ = pl011;
}
