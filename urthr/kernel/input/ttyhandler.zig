//! Key event handler for the terminal.
//!
//! Translates key events into characters and feeds them to the line discipline.

pub const handler = Handler{
    .onKey = onKey,
};

fn onKey(dev: *Device, key: Key, state: Device.KeyState) void {
    if (state == .release) return;

    const mods = keymap.Modifiers{
        .shift = dev.isPressed(.leftshift) or dev.isPressed(.rightshift),
        .ctrl = dev.isPressed(.leftctrl) or dev.isPressed(.rightctrl),
    };
    for (keymap.toChars(key, mods)) |c| {
        ldisc.push(c);
    }
}

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const Key = common.input_codes.Key;
const Device = @import("Device.zig");
const Handler = @import("Handler.zig");
const keymap = @import("keymap.zig");
const ldisc = @import("ldisc.zig");
