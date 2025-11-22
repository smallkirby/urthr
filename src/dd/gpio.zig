// =============================================================
// Module Definition
// =============================================================

var gpio = Module{};

const Module = mmio.Module(u32, &.{
    .{ 0x00, Gpfsel0 },
    .{ 0x04, Gpfsel1 },
    .{ 0x08, Gpfsel2 },
    .{ 0x0C, Gpfsel3 },
    .{ 0x10, Gpfsel4 },
    .{ 0x14, Gpfsel5 },
});

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

/// GPFSEL0
const Gpfsel0 = packed struct(u32) {
    fsel0: Fsel,
    fsel1: Fsel,
    fsel2: Fsel,
    fsel3: Fsel,
    fsel4: Fsel,
    fsel5: Fsel,
    fsel6: Fsel,
    fsel7: Fsel,
    fsel8: Fsel,
    fsel9: Fsel,
    _rsvd: u2 = 0,
};

/// GPFSEL1
const Gpfsel1 = packed struct(u32) {
    fsel10: Fsel,
    fsel11: Fsel,
    fsel12: Fsel,
    fsel13: Fsel,
    fsel14: Fsel,
    fsel15: Fsel,
    fsel16: Fsel,
    fsel17: Fsel,
    fsel18: Fsel,
    fsel19: Fsel,
    _rsvd: u2 = 0,
};

/// GPFSEL2
const Gpfsel2 = packed struct(u32) {
    fsel20: Fsel,
    fsel21: Fsel,
    fsel22: Fsel,
    fsel23: Fsel,
    fsel24: Fsel,
    fsel25: Fsel,
    fsel26: Fsel,
    fsel27: Fsel,
    fsel28: Fsel,
    fsel29: Fsel,
    _rsvd: u2 = 0,
};

/// GPFSEL3
const Gpfsel3 = packed struct(u32) {
    fsel30: Fsel,
    fsel31: Fsel,
    fsel32: Fsel,
    fsel33: Fsel,
    fsel34: Fsel,
    fsel35: Fsel,
    fsel36: Fsel,
    fsel37: Fsel,
    fsel38: Fsel,
    fsel39: Fsel,
    _rsvd: u2 = 0,
};

/// GPFSEL4
const Gpfsel4 = packed struct(u32) {
    fsel40: Fsel,
    fsel41: Fsel,
    fsel42: Fsel,
    fsel43: Fsel,
    fsel44: Fsel,
    fsel45: Fsel,
    fsel46: Fsel,
    fsel47: Fsel,
    fsel48: Fsel,
    fsel49: Fsel,
    _rsvd: u2 = 0,
};

/// GPFSEL5
const Gpfsel5 = packed struct(u32) {
    fsel50: Fsel,
    fsel51: Fsel,
    fsel52: Fsel,
    fsel53: Fsel,
    fsel54: Fsel,
    fsel55: Fsel,
    fsel56: Fsel,
    fsel57: Fsel,
    _rsvd: u8 = 0,
};

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
    const Gpfsel = mmio.Register(u32, u32);
    const addr = gpio.base + reg_index * 4;

    const old = Gpfsel.read(addr);
    const shift: u5 = @intCast(@bitSizeOf(Fsel) * field_index);
    const mask = @as(u32, 0b111) << shift;
    const new = (old & ~mask) | @as(u32, @intFromEnum(alt)) << shift;
    Gpfsel.write(addr, new);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const urd = @import("urthr");
const mmio = urd.mmio;
