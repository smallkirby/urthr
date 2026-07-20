//! Intel 8254 Programmable Interval Timer.

var pit = pio.Module(&.{
    .{ 0x40, Chan0Data },
    .{ 0x41, Chan1Data },
    .{ 0x42, Chan2Data },
    .{ 0x43, ModeCommand },
    .{ 0x61, Chan2Control },
}){ .base = 0 };

// =============================================================

/// Oscillator frequency of the PIT in Hz.
const base_freq: u32 = 1_193_182;

/// Calibrate the TSC frequency against PIT channel 2.
///
/// Blocks for approximately `ms` milliseconds.
/// `ms` must be small enough that the resulting count fits in 16 bits.
pub fn calibrateTsc(ms: u32) u64 {
    const count: u16 = @intCast(base_freq / 1000 * ms);

    // Enable the channel 2 gate and disable the speaker output.
    const prev = pit.read(Chan2Control);
    pit.modify(Chan2Control, .{
        .gate = true,
        .speaker = false,
    });

    // Program channel 2 for a one-shot count.
    pit.writez(ModeCommand, .{
        .mode = .mode0,
        .access = .lohi,
        .channel = 2,
    });
    pit.writei(Chan2Data, @as(u8, @truncate(count)));
    pit.writei(Chan2Data, @as(u8, @truncate(count >> 8)));

    // Channel 2's output starts low and goes high when the count reaches zero.
    const start = am.rdtsc();
    while (!pit.read(Chan2Control).out) {
        std.atomic.spinLoopHint();
    }
    const end = am.rdtsc();

    // Restore the previous channel 2 control state.
    pit.write(Chan2Control, prev);

    return (end - start) * 1_000 / ms;
}

// =============================================================
// Registers
// =============================================================

const Chan0Data = packed struct(u8) {
    data: u8,
};

const Chan1Data = packed struct(u8) {
    data: u8,
};

const Chan2Data = packed struct(u8) {
    data: u8,
};

const ModeCommand = packed struct(u8) {
    /// BCD/Binary mode.
    bcd: enum(u1) { binary = 0, bcd = 1 },
    /// Operating mode.
    mode: enum(u3) {
        /// Interrupt on terminal count.
        mode0 = 0,
        /// Hardware re-triggerable one-shot.
        mode1 = 1,
        /// Rate generator.
        mode2 = 2,
        /// Square wave generator.
        mode3 = 3,
        /// Software triggered strobe.
        mode4 = 4,
        /// Hardware triggered strobe.
        mode5 = 5,
    },
    /// Access mode.
    access: enum(u2) {
        /// Latch count value command.
        latch = 0,
        /// Access mode: lobyte only.
        lobyte = 1,
        /// Access mode: hibyte only.
        hibyte = 2,
        /// Access mode: lobyte/hibyte.
        lohi = 3,
    },
    /// Select channel.
    channel: u2,
};

const Chan2Control = packed struct(u8) {
    /// Channel 2 gate control.
    gate: bool,
    /// Speaker output enable.
    speaker: bool,
    /// Don't care.
    _2: u3,
    /// Channel 2 output.
    out: bool,
    /// Don't care.
    _6: u2,
};

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const pio = common.pio;
const std = @import("std");
const am = @import("asm.zig");
