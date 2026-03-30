//! brcm2711-rng200 Random Number Generator.
//!
//! ref. https://github.com/raspberrypi/linux/blob/5f23da14d91d4ba66604ec75453564e4e2afc57e/drivers/char/hw_random/iproc-rng200.c

// =============================================================
// Module Definition
// =============================================================

var rng = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, Ctrl },
    .{ 0x0C, TotalBitCount },
    .{ 0x20, FifoData },
    .{ 0x24, FifoCount },
}){};

// =============================================================

/// Set the base address of the RNG.
pub fn setBase(base: usize) void {
    rng.setBase(base);
}

/// Initialize RNG module.
pub fn init() void {
    rng.modify(Ctrl, .{
        .rbgen_enable = true,
        .rbgen = 0,
    });
}

/// Read random data into the buffer.
///
/// This function does not guarantee to fill the entire buffer.
/// Returns the slice of the buffer that has been filled.
pub fn read(buf: []u8) []u8 {
    rtt.expectEqual(0, buf.len % 4);

    const max_words = buf.len / 4;
    var out = @as([*]align(1) u32, @ptrCast(buf.ptr))[0..max_words];

    // Ensure warm up period has elapsed.
    while (rng.read(TotalBitCount).value <= 16) {
        std.atomic.spinLoopHint();
    }

    // Ensure FIFO is not empty.
    var num_words = while (true) {
        const count = rng.read(FifoCount).count;
        if (count > 0) break count;
        std.atomic.spinLoopHint();
    };
    num_words = @min(num_words, max_words);

    // Read random data from FIFO.
    for (0..num_words) |i| {
        out[i] = rng.read(FifoData).value;
    }

    return @as([*]u8, @ptrCast(out.ptr))[0 .. num_words * 4];
}

// =============================================================
// Registers
// =============================================================

const Ctrl = packed struct(u32) {
    rbgen_enable: bool,
    rbgen: u12,
    _13: u19,
};

const TotalBitCount = packed struct(u32) {
    value: u32,
};

const FifoCount = packed struct(u32) {
    count: u8,
    _8: u24,
};

const FifoData = packed struct(u32) {
    value: u32,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const rtt = common.rtt;
const mmio = common.mmio;
const arch = @import("arch").impl;
