//! USB HID usage translation.
//!
//! ref. HID Usage Tables Version 1.12

/// Convert a usage ID of the Keyboard/Keypad page to a key code.
///
/// Returns null if the usage has no corresponding key.
pub fn keyboard(id: u8) ?Key {
    const key = keyboard_table[id];
    return if (key == .reserved) null else key;
}

/// Key codes indexed by the usage ID of the Keyboard/Keypad page.
const keyboard_table = blk: {
    var t: [256]Key = @splat(.reserved);

    setRange(&t, 0x04, &.{
        .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
        .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z,
    });
    setRange(&t, 0x1E, &.{
        .@"1", .@"2", .@"3", .@"4", .@"5", .@"6", .@"7", .@"8", .@"9", .@"0",
    });
    setRange(&t, 0x28, &.{
        .enter, .esc,   .backspace, .tab,        .space,
        .minus, .equal, .leftbrace, .rightbrace,
        .backslash, .backslash, // Non-US # and ~
        .semicolon, .apostrophe,
        .grave,     .comma,
        .dot,       .slash,
    });
    setRange(&t, 0x39, &.{
        .capslock,   .f1,   .f2,      .f3,       .f4,         .f5,       .f6,         .f7,
        .f8,         .f9,   .f10,     .f11,      .f12,        .sysrq,    .scrolllock, .pause,
        .insert,     .home, .pageup,  .delete,   .end,        .pagedown, .right,      .left,
        .down,       .up,   .numlock, .kpslash,  .kpasterisk, .kpminus,  .kpplus,     .kpenter,
        .kp1,        .kp2,  .kp3,     .kp4,      .kp5,        .kp6,      .kp7,        .kp8,
        .kp9,        .kp0,  .kpdot,   .@"102nd", .compose,    .power,    .kpequal,    .f13,
        .f14,        .f15,  .f16,     .f17,      .f18,        .f19,      .f20,        .f21,
        .f22,        .f23,  .f24,     .open,     .help,       .props,    .front,      .stop,
        .again,      .undo, .cut,     .copy,     .paste,      .find,     .mute,       .volumeup,
        .volumedown,
    });
    setRange(&t, 0x85, &.{
        .kpcomma,
    });
    setRange(&t, 0x87, &.{
        .ro, .katakanahiragana, .yen, .henkan, .muhenkan, .kpjpcomma,
    });
    setRange(&t, 0x90, &.{
        .hangeul, .hanja, .katakana, .hiragana, .zenkakuhankaku,
    });
    setRange(&t, 0x9C, &.{
        .delete,
    });
    setRange(&t, 0xB6, &.{
        .kpleftparen, .kprightparen,
    });
    setRange(&t, 0xE0, &.{
        .leftctrl,  .leftshift,  .leftalt,  .leftmeta,
        .rightctrl, .rightshift, .rightalt, .rightmeta,
    });

    break :blk t;
};

/// Assign consecutive keys to the table, starting from the given usage ID.
fn setRange(table: *[256]Key, comptime first: u8, comptime keys: []const Key) void {
    for (keys, first..) |key, id| table[id] = key;
}

// =============================================================
// Tests
// =============================================================

const testing = std.testing;

test "keyboard: normal" {
    try testing.expectEqual(.a, keyboard(0x04));
    try testing.expectEqual(.z, keyboard(0x1D));
    try testing.expectEqual(.@"1", keyboard(0x1E));
    try testing.expectEqual(.@"0", keyboard(0x27));
    try testing.expectEqual(.enter, keyboard(0x28));
    try testing.expectEqual(.slash, keyboard(0x38));
    try testing.expectEqual(.capslock, keyboard(0x39));
    try testing.expectEqual(.f1, keyboard(0x3A));
    try testing.expectEqual(.f12, keyboard(0x45));
    try testing.expectEqual(.right, keyboard(0x4F));
    try testing.expectEqual(.up, keyboard(0x52));
    try testing.expectEqual(.kp1, keyboard(0x59));
    try testing.expectEqual(.kp0, keyboard(0x62));
    try testing.expectEqual(.f13, keyboard(0x68));
    try testing.expectEqual(.f24, keyboard(0x73));
    try testing.expectEqual(.volumedown, keyboard(0x81));
}

test "keyboard: modifiers" {
    const expected = [_]Key{
        .leftctrl,  .leftshift,  .leftalt,  .leftmeta,
        .rightctrl, .rightshift, .rightalt, .rightmeta,
    };
    for (expected, 0xE0..) |key, id| {
        try testing.expectEqual(key, keyboard(@intCast(id)));
    }
}

test "keyboard: unassigned usages" {
    // No event, error roll over, POST fail, and undefined error.
    for (0x00..0x04) |id| {
        try testing.expectEqual(null, keyboard(@intCast(id)));
    }
    try testing.expectEqual(null, keyboard(0x82));
    try testing.expectEqual(null, keyboard(0xA0));
    try testing.expectEqual(null, keyboard(0xE8));
    try testing.expectEqual(null, keyboard(0xFF));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const Key = common.input_codes.Key;
