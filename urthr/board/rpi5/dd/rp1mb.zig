//! RP1 Mailbox.

// =============================================================
// Module Definition
// =============================================================

var mb = mmio.Module(.{ .natural = u32 }, &.{
    .{ 0x0008, ProcEvents },
    .{ 0x0010, HostEventIrqEn },
    .{ 0x0014, HostEventIrq },

    .{ 0x0008 + offset_hw_set, ProcEventsSet },
    .{ 0x0010 + offset_hw_set, HostEventIrqEnSet },
    .{ 0x0014 + offset_hw_set, HostEventIrqSet },

    .{ 0x0008 + offset_hw_clear, ProcEventsClr },
    .{ 0x0010 + offset_hw_clear, HostEventIrqEnClr },
    .{ 0x0014 + offset_hw_clear, HostEventIrqClr },
}){};

/// Offset to HW_SET register from ProcEvents register.
const offset_hw_set = 0x2000;
/// Offset to HW_CLR register from ProcEvents register.
const offset_hw_clear = 0x3000;

// =============================================================
// API
// =============================================================

/// Initialize the mailbox.
pub fn init(base: usize) void {
    // Set the base address of the mailbox.
    mb.setBase(base);

    // Enable interrupts.
    {
        var mask: u32 = 0;
        for (Channel.avails) |chan| {
            mask = bits.set(mask, @as(u32, @intFromEnum(chan)));
        }
        mb.write(HostEventIrqEnSet, mask);
    }
}

/// Generate interrupts on the M3 cores.
pub fn notify(chan: Channel) void {
    mb.write(ProcEventsSet, bits.set(@as(u32, 0), @intFromEnum(chan)));
}

/// Check if there's a pending interrupt on the given channel.
pub fn checkIrq(chan: Channel) bool {
    const channels = mb.read(HostEventIrq).channel;

    return bits.isset(channels, @intFromEnum(chan));
}

/// Clear interrupt on the given channel.
pub fn clearIrq(chan: Channel) void {
    mb.write(HostEventIrqEnClr, bits.set(@as(u32, 0), @intFromEnum(chan)));
}

/// Mailbox channels.
const Channel = enum(u5) {
    /// Firmware.
    fw = 0,

    _,

    /// Available channels.
    const avails = [_]Channel{
        .fw,
    };
};

// =============================================================
// I/O Registers
// =============================================================

const ProcEvents = packed struct(u32) {
    channel: u32,
};

const ProcEventsSet = packed struct(u32) {
    channel: u32,
};

const ProcEventsClr = packed struct(u32) {
    channel: u32,
};

const HostEventIrq = packed struct(u32) {
    channel: u32,
};

const HostEventIrqSet = packed struct(u32) {
    channel: u32,
};

const HostEventIrqClr = packed struct(u32) {
    channel: u32,
};

const HostEventIrqEn = packed struct(u32) {
    channel: u32,
};

const HostEventIrqEnSet = packed struct(u32) {
    channel: u32,
};

const HostEventIrqEnClr = packed struct(u32) {
    channel: u32,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.rp1mb);
const common = @import("common");
const bits = common.bits;
const mmio = common.mmio;
