//! BCM2712 ARM-to-VideoCore Mailbox.
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
    mbox.write(Mbox1Write, .{
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
// Properties
// =============================================================

pub const props = struct {
    // Tag IDs.
    pub const tags = struct {
        /// End tag.
        pub const end: u32 = 0x0000_0000;
        /// Get the max supported clock rate for the given clock.
        pub const get_max_clock_rate: u32 = 0x0003_0004;
        /// Allocate buffer.
        pub const alloc_buf: u32 = 0x0004_0001;
        /// Get pitch.
        pub const get_pitch: u32 = 0x0004_0008;
        /// Set physical (display) width / height
        pub const set_phys_wh: u32 = 0x0004_8003;
        /// Set virtual (buffer) width / height
        pub const set_virt_wh: u32 = 0x0004_8004;
        /// Set depth.
        pub const set_depth: u32 = 0x0004_8005;
        /// Set pixel order.
        pub const set_pixel_order: u32 = 0x0004_8006;
        /// Set virtual offset.
        pub const set_virt_off: u32 = 0x0004_8009;
    };

    /// Utility struct to build mailbox messages.
    pub const MessageBuilder = struct {
        /// Message buffer.
        buf: []u32,
        /// Current index in the message buffer.
        index: usize,

        pub fn init(buf: []u32) MessageBuilder {
            @memset(buf, 0);

            return .{
                .buf = buf,
                .index = 2,
            };
        }

        pub fn push(self: *MessageBuilder, value: u32) void {
            self.buf[self.index] = value;
            self.index += 1;
        }

        pub fn getIndex(self: *const MessageBuilder) usize {
            return self.index;
        }

        pub fn finalize(self: *MessageBuilder) void {
            self.push(tags.end);

            self.buf[0] = @intCast(self.index * @sizeOf(u32));
            self.buf[1] = 0x0000_0000; // process request
        }
    };
};

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
