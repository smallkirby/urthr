//! BCM2711 ARM-to-VideoCore Mailbox.
//!
//! ref. https://github.com/raspberrypi/firmware/wiki/Mailboxes
//! ref. https://github.com/raspberrypi/firmware/wiki/Accessing-mailboxes

// =============================================================
// Module Definition
// =============================================================

var mbox = mmio.Module(.{ .size = u32 }, &.{
    // MB#0 is always for VC to ARM. Can't write to it.
    .{ 0x00, Mbox0Read },
    .{ 0x18, Mbox0Status },
    // MB#1 is always for ARM to VC. Can't read from it.
    .{ 0x20, Mbox1Write },
    .{ 0x38, Mbox1Status },
}){};

// =============================================================
// API
// =============================================================

/// Set the base address of the mailbox registers.
pub fn setBase(base: usize) void {
    mbox.setBase(base);
}

/// Send a property message to VideoCore and wait for the response.
pub fn call(channel: Channels, phys: u32) void {
    // Read the status register until the full flag is not set.
    while (mbox.read(Mbox1Status).full) {
        std.atomic.spinLoopHint();
    }

    // Write the data combined with the channel.
    mbox.write(Mbox1Write, Mbox1Write{
        .channel = channel,
        .data = @as(u28, @truncate(phys >> 4)),
    });

    // Wait for the response.
    while (true) {
        while (mbox.read(Mbox0Status).empty) {
            std.atomic.spinLoopHint();
        }

        if (mbox.read(Mbox0Read).channel == channel) {
            break;
        }
    }
}

// =============================================================
// Registers
// =============================================================

/// Available mailbox channels.
const Channels = enum(u4) {
    /// Power management.
    pm = 0,
    /// Framebuffer.
    fb = 1,
    /// Virtual UART.
    uart = 2,
    /// VCHIQ (VideoCore Host Interface Queue).
    vchiq = 3,
    /// LEDs.
    leds = 4,
    /// Buttons.
    buttons = 5,
    /// Touchscreen.
    touch = 6,
    /// Unused.
    unused = 7,
    /// Property tags (ARM to VC).
    prop2vc = 8,
    /// Property tags (VC to ARM).
    prop2cpu = 9,
};

const Mbox0Read = packed struct(u32) {
    channel: Channels,
    data: u28,
};

const Mbox0Status = packed struct(u32) {
    _0: u30 = 0,
    empty: bool,
    full: bool,
};

const Mbox1Write = packed struct(u32) {
    channel: Channels,
    data: u28,
};

const Mbox1Status = packed struct(u32) {
    _0: u30 = 0,
    empty: bool,
    full: bool,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const mmio = common.mmio;
