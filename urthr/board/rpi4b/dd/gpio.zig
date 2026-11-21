// =============================================================
// Module Definition
// =============================================================

var gpio = mmio.Module(.{ .size = u32 }, .{
    Arr(0x00, u32, 6, 4).as(.gpfsel),
}){};

// =============================================================

/// Set the base address of the GPIO module.
pub fn setBase(base: usize) void {
    gpio.setBase(base);
}

/// Select the alternate function for the specified GPIO pin.
pub fn selectAltFn(pin: u8, alt: Fsel) void {
    const reg_index = pin / 10;
    const field_index = pin % 10;

    if (5 < reg_index) {
        @panic("selectAltFn(): GPIO pin out of range.");
    }
    const old = gpio.readIndexed(.gpfsel, reg_index);
    const shift: u5 = @intCast(@bitSizeOf(Fsel) * field_index);
    const mask = @as(u32, 0b111) << shift;
    const new = (old & ~mask) | @as(u32, @backingInt(alt)) << shift;
    gpio.writeIndexed(.gpfsel, reg_index, new);
}

// =============================================================
// Registers
// =============================================================

const Fsel = enum(u3) {
    input = 0b000,
    output = 0b001,
    alt0 = 0b100,
    alt1 = 0b101,
    alt2 = 0b110,
    alt3 = 0b111,
    alt4 = 0b011,
    alt5 = 0b010,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const io = common.io;
const mmio = io.mmio;
const Arr = io.Arr;
