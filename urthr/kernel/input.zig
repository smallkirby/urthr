//! Kernel input subsystem.

pub const keymap = @import("input/keymap.zig");
pub const ldisc = @import("input/ldisc.zig");

test {
    _ = keymap;
}
