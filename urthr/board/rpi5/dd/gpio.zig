//! Raspberry Pi RP1 GPIO unit.
//!
//! - ref. https://github.com/raspberrypi/linux/blob/3b2b4267d502acb3f9183ceca20719c30e60fca3/drivers/pinctrl/pinctrl-rp1.c
//! - ref. https://github.com/raspberrypi/utils/blob/230d67ad28e74b17a42064453b2163991cb51a5e/pinctrl/gpiochip_rp1.c

// =============================================================
// Module Definition
// =============================================================

/// GPIO module.
const Gpio = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, Status },
    .{ 0x04, Ctrl },
});

/// RIO (Registered I/O) module.
const Rio = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, RioOut },
    .{ 0x04, RioOe },

    .{ 0x00 + rio_set_offset, RioOutSet },
    .{ 0x04 + rio_set_offset, RioOeSet },

    .{ 0x00 + rio_clr_offset, RioOutClr },
    .{ 0x04 + rio_clr_offset, RioOeClr },
});

/// PADs module.
const Pads = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, VoltageSelect },
    .{ 0x04, Pad },
});

/// Function select definitions.
const functions = &[_]Funcs{
    // Bank 0 (GPIO 0-27)
    .def(0, .{ .spi0, .dpi, .uart1, .i2c0, null, .gpio, .proc_rio, .pio, .spi2 }),
    .def(1, .{ .spi0, .dpi, .uart1, .i2c0, null, .gpio, .proc_rio, .pio, .spi2 }),
    .def(2, .{ .spi0, .dpi, .uart1, .i2c1, .ir, .gpio, .proc_rio, .pio, .spi2 }),
    .def(3, .{ .spi0, .dpi, .uart1, .i2c1, .ir, .gpio, .proc_rio, .pio, .spi2 }),
    .def(4, .{ .gpclk0, .dpi, .uart2, .i2c2, .ri0, .gpio, .proc_rio, .pio, .spi3 }),
    .def(5, .{ .gpclk1, .dpi, .uart2, .i2c2, .dtr0, .gpio, .proc_rio, .pio, .spi3 }),
    .def(6, .{ .gpclk2, .dpi, .uart2, .i2c3, .dcd0, .gpio, .proc_rio, .pio, .spi3 }),
    .def(7, .{ .spi0, .dpi, .uart2, .i2c3, .dsr0, .gpio, .proc_rio, .pio, .spi3 }),
    .def(8, .{ .spi0, .dpi, .uart3, .i2c0, null, .gpio, .proc_rio, .pio, .spi4 }),
    .def(9, .{ .spi0, .dpi, .uart3, .i2c0, null, .gpio, .proc_rio, .pio, .spi4 }),
    .def(10, .{ .spi0, .dpi, .uart3, .i2c1, null, .gpio, .proc_rio, .pio, .spi4 }),
    .def(11, .{ .spi0, .dpi, .uart3, .i2c1, null, .gpio, .proc_rio, .pio, .spi4 }),
    .def(12, .{ .pwm0, .dpi, .uart4, .i2c2, .aaud, .gpio, .proc_rio, .pio, .spi5 }),
    .def(13, .{ .pwm0, .dpi, .uart4, .i2c2, .aaud, .gpio, .proc_rio, .pio, .spi5 }),
    .def(14, .{ .pwm0, .dpi, .uart4, .i2c3, .uart0, .gpio, .proc_rio, .pio, .spi5 }),
    .def(15, .{ .pwm0, .dpi, .uart4, .i2c3, .uart0, .gpio, .proc_rio, .pio, .spi5 }),
    .def(16, .{ .spi1, .dpi, .dsi0_te_ext, null, .uart0, .gpio, .proc_rio, .pio, null }),
    .def(17, .{ .spi1, .dpi, .dsi1_te_ext, null, .uart0, .gpio, .proc_rio, .pio, null }),
    .def(18, .{ .spi1, .dpi, .i2s0, .pwm0, .i2s1, .gpio, .proc_rio, .pio, .gpclk1 }),
    .def(19, .{ .spi1, .dpi, .i2s0, .pwm0, .i2s1, .gpio, .proc_rio, .pio, null }),
    .def(20, .{ .spi1, .dpi, .i2s0, .gpclk0, .i2s1, .gpio, .proc_rio, .pio, null }),
    .def(21, .{ .spi1, .dpi, .i2s0, .gpclk1, .i2s1, .gpio, .proc_rio, .pio, null }),
    .def(22, .{ .sd0clk, .dpi, .i2s0, .i2c3, .i2s1, .gpio, .proc_rio, .pio, null }),
    .def(23, .{ .sd0cmd, .dpi, .i2s0, .i2c3, .i2s1, .gpio, .proc_rio, .pio, null }),
    .def(24, .{ .sd0dat0, .dpi, .i2s0, null, .i2s1, .gpio, .proc_rio, .pio, .spi2 }),
    .def(25, .{ .sd0dat1, .dpi, .i2s0, .mic, .i2s1, .gpio, .proc_rio, .pio, .spi3 }),
    .def(26, .{ .sd0dat2, .dpi, .i2s0, .mic, .i2s1, .gpio, .proc_rio, .pio, .spi5 }),
    .def(27, .{ .sd0dat3, .dpi, .i2s0, .mic, .i2s1, .gpio, .proc_rio, .pio, .spi1 }),
    // Bank 1 (GPIO 28-33)
    .def(28, .{ .sd1clk, .i2c4, .i2s2, .spi6, .vbus0, .gpio, .proc_rio, null, null }),
    .def(29, .{ .sd1cmd, .i2c4, .i2s2, .spi6, .vbus0, .gpio, .proc_rio, null, null }),
    .def(30, .{ .sd1dat0, .i2c5, .i2s2, .spi6, .uart5, .gpio, .proc_rio, null, null }),
    .def(31, .{ .sd1dat1, .i2c5, .i2s2, .spi6, .uart5, .gpio, .proc_rio, null, null }),
    .def(32, .{ .sd1dat2, .gpclk3, .i2s2, .spi6, .uart5, .gpio, .proc_rio, null, null }),
    .def(33, .{ .sd1dat3, .gpclk4, .i2s2, .spi6, .uart5, .gpio, .proc_rio, null, null }),
    // Bank 2 (GPIO 34-53)
    .def(34, .{ .pwm1, .gpclk3, .vbus0, .i2c4, .mic, .gpio, .proc_rio, null, null }),
    .def(35, .{ .spi8, .pwm1, .vbus0, .i2c4, .mic, .gpio, .proc_rio, null, null }),
    .def(36, .{ .spi8, .uart5, .pcie_clkreq_n, .i2c5, .mic, .gpio, .proc_rio, null, null }),
    .def(37, .{ .spi8, .uart5, .mic, .i2c5, .pcie_clkreq_n, .gpio, .proc_rio, null, null }),
    .def(38, .{ .spi8, .uart5, .mic, .i2c6, .aaud, .gpio, .proc_rio, .dsi0_te_ext, null }),
    .def(39, .{ .spi8, .uart5, .mic, .i2c6, .aaud, .gpio, .proc_rio, .dsi1_te_ext, null }),
    .def(40, .{ .pwm1, .uart5, .i2c4, .spi6, .aaud, .gpio, .proc_rio, null, null }),
    .def(41, .{ .pwm1, .uart5, .i2c4, .spi6, .aaud, .gpio, .proc_rio, null, null }),
    .def(42, .{ .gpclk5, .uart5, .vbus1, .spi6, .i2s2, .gpio, .proc_rio, null, null }),
    .def(43, .{ .gpclk4, .uart5, .vbus1, .spi6, .i2s2, .gpio, .proc_rio, null, null }),
    .def(44, .{ .gpclk5, .i2c5, .pwm1, .spi6, .i2s2, .gpio, .proc_rio, null, null }),
    .def(45, .{ .pwm1, .i2c5, .spi7, .spi6, .i2s2, .gpio, .proc_rio, null, null }),
    .def(46, .{ .gpclk3, .i2c4, .spi7, .mic, .i2s2, .gpio, .proc_rio, .dsi0_te_ext, null }),
    .def(47, .{ .gpclk5, .i2c4, .spi7, .mic, .i2s2, .gpio, .proc_rio, .dsi1_te_ext, null }),
    .def(48, .{ .pwm1, .pcie_clkreq_n, .spi7, .mic, .uart5, .gpio, .proc_rio, null, null }),
    .def(49, .{ .spi8, .spi7, .i2c5, .aaud, .uart5, .gpio, .proc_rio, null, null }),
    .def(50, .{ .spi8, .spi7, .i2c5, .aaud, .vbus2, .gpio, .proc_rio, null, null }),
    .def(51, .{ .spi8, .spi7, .i2c6, .aaud, .vbus2, .gpio, .proc_rio, null, null }),
    .def(52, .{ .spi8, null, .i2c6, .aaud, .vbus3, .gpio, .proc_rio, null, null }),
    .def(53, .{ .spi8, .spi7, null, .pcie_clkreq_n, .vbus3, .gpio, .proc_rio, null, null }),
};

/// Base address of I/O bank 0.
var gpio_base: usize = undefined;
/// Base address of RIO bank 0.
var rio_base: usize = undefined;
/// Base address of PADs bank 0.
var pads_base: usize = undefined;

// =============================================================
// APIs
// =============================================================

/// Pin number type.
const Pin = u8;
/// Type of function select ID.
const FselId = @Type(.enum_literal);

/// Function select.
const Funcs = struct {
    /// Number of function select options.
    const num_fsels = 9;

    /// GPIO pin number.
    pin: Pin,
    /// Functions.
    funcs: [num_fsels]?FselId,

    pub fn def(comptime pin: Pin, comptime funcs: [num_fsels]?FselId) Funcs {
        return .{
            .pin = pin,
            .funcs = funcs,
        };
    }
};

/// Set the base address of I/O bank, RIO bank, and PADs bank.
pub fn setBase(io: usize, rio: usize, pads: usize) void {
    gpio_base = io;
    rio_base = rio;
    pads_base = pads;
}

/// Select GPIO function for the given pin.
pub fn setFunction(comptime pin: Pin, function: FselId) void {
    const info = getPinInfo(pin);

    // Select function.
    info.gpio.writeIndexed(Ctrl, info.pin_offset, 8, std.mem.zeroInit(Ctrl, .{
        .funcsel = getFunctionNumber(pin, function),
        .oeover = .normal,
        .outover = .normal,
    }));

    // Enable input and output.
    info.pads.writeIndexed(Pad, info.pin_offset, 4, std.mem.zeroInit(Pad, .{
        .ie = true,
        .od = false,
    }));
}

/// Set pull-up/down configuration for the given pin.
pub fn setPull(pin: u8, pull: PullType) void {
    const info = getPinInfo(pin);

    info.pads.modifyIndexed(Pad, info.pin_offset, 4, .{
        .pue = pull == .up,
        .pde = pull == .down,
        .drive = .ma12,
        .slewfast = .fast,
        .schmitt = true,
    });
}

/// Get pull-up/down configuration for the given pin.
pub fn getPull(pin: u8) PullType {
    const info = getPinInfo(pin);
    const pad = info.pads.readIndexed(Pad, info.pin_offset, 4);

    return if (pad.pue) .up else if (pad.pde) .down else .off;
}

/// Set output value for the given pin.
pub fn setOutput(pin: Pin, high: bool) void {
    const info = getPinInfo(pin);
    const mask = bits.set(@as(u32, 0), info.pin_offset);

    // Set direction to output.
    info.rio.write(RioOeSet, mask);

    // Set output value
    if (high) {
        info.rio.write(RioOutSet, mask);
    } else {
        info.rio.write(RioOutClr, mask);
    }
}

/// Pin information.
const PinInfo = struct {
    /// Bank number.
    bank: u2,
    /// GPIO bank.
    gpio: Gpio,
    /// RIO bank.
    rio: Rio,
    /// PADs bank.
    pads: Pads,
    /// Pin number within the bank.
    pin_offset: Pin,
};

/// Bias pull-up/down type.
pub const PullType = enum {
    /// Bias disable (no pull-up or pull-down).
    off,
    /// Pull-down.
    down,
    /// Pull-up.
    up,
};

/// Get the pin information for the given GPIO pin.
fn getPinInfo(pin: Pin) PinInfo {
    const offset_bank0 = 0x0000;
    const offset_bank1 = 0x4000;
    const offset_bank2 = 0x8000;

    const min_pin_bank1 = 28;
    const min_pin_bank2 = 34;

    const bank: u2 = if (pin < min_pin_bank1)
        0
    else if (pin < min_pin_bank2)
        1
    else
        2;
    const pin_offset = if (bank == 0)
        pin
    else if (bank == 1)
        pin - min_pin_bank1
    else
        pin - min_pin_bank2;

    var gpio = Gpio{};
    var rio = Rio{};
    var pads = Pads{};

    switch (bank) {
        0 => {
            gpio.setBase(gpio_base + offset_bank0);
            rio.setBase(rio_base + offset_bank0);
            pads.setBase(pads_base + offset_bank0);
        },
        1 => {
            gpio.setBase(gpio_base + offset_bank1);
            rio.setBase(rio_base + offset_bank1);
            pads.setBase(pads_base + offset_bank1);
        },
        2 => {
            gpio.setBase(gpio_base + offset_bank2);
            rio.setBase(rio_base + offset_bank2);
            pads.setBase(pads_base + offset_bank2);
        },
        else => unreachable,
    }

    return PinInfo{
        .bank = bank,
        .gpio = gpio,
        .rio = rio,
        .pads = pads,
        .pin_offset = pin_offset,
    };
}

/// Get the function select number for the given pin and function.
fn getFunctionNumber(comptime pin: Pin, func: FselId) u5 {
    inline for (functions[pin].funcs, 0..) |f, i| {
        if (f == func) return @intCast(i);
    } else @compileError("Function not supported for the given pin.");
}

// =============================================================
// I/O Registers
// =============================================================

// =============================================================
// GPIO

/// GPIO<n>_STATUS register.
const Status = packed struct(u32) {
    /// Reserved.
    _rsvd0: u8 = 0,
    /// Output signal from selected peripheral.
    outfromperi: bool,
    /// Output signal to pad after register override is applied.
    outtopad: bool,
    /// Reserved.
    _rsvd1: u2 = 0,
    /// Output enable from selected peripheral, before register override is applied.
    oefromperi: bool,
    /// Output enable to pad after register override is applied.
    oetopad: bool,
    /// Reserved.
    _rsvd2: u2 = 0,
    /// Input signal from pad, goes directly to the selected peripheral without filtering or override.
    inisdirect: bool,
    /// Input signal from pad, before filter and override are applied.
    infrompad: bool,
    /// Input signal from pad, after filtering is applied but before override.
    infiltered: bool,
    /// Input signal to peripheral, after filtering and override are applied.
    intoperi: bool,
    /// Input pin has seen falling edge.
    event_edge_low: bool,
    /// Input pin has seen rising edge.
    event_edge_high: bool,
    /// Input pin is Low.
    event_level_low: bool,
    /// Input pin is High.
    event_level_high: bool,
    /// Input pin has seen a filtered falling edge.
    event_f_edge_low: bool,
    /// Input pin has seen a filtered rising edge.
    event_f_edge_high: bool,
    /// Debounced input pin is Low.
    event_db_level_low: bool,
    /// Debounced input pin is High.
    event_db_level_high: bool,
    /// Interrupt to processors, after masking.
    irqcombined: bool,
    /// Interrupt to processors, after mask and override is applied.
    irqtoproc: bool,
    /// Reserved.
    _rsvd: u2 = 0,
};

/// GPIO<n>_CTRL register.
const Ctrl = packed struct(u32) {
    /// Function select.
    funcsel: u5,
    /// Filter / debounce time constant M.
    f_m: u7,
    /// Drive output value.
    outover: SignalOverride,
    /// Drive output enable.
    oeover: SignalOverride,
    /// Input signal override.
    inover: SignalOverride,
    /// Reserved.
    _rsvd0: u2 = 0,
    /// Masks the edge low interrupt into the interrupt output.
    irqmask_edge_low: bool,
    /// Masks the edge high interrupt into the interrupt output.
    irqmask_edge_high: bool,
    /// Masks the level low interrupt into the interrupt output.
    irqmask_level_low: bool,
    /// Masks the level high interrupt into the interrupt output.
    irqmask_level_high: bool,
    /// Masks the filtered edge low interrupt into the interrupt output.
    irqmask_f_edge_low: bool,
    /// Masks the filtered edge high interrupt into the interrupt output.
    irqmask_f_edge_high: bool,
    /// Masks the debounced level low interrupt into the interrupt output.
    irqmask_db_level_low: bool,
    /// Masks the debounced level high interrupt into the interrupt output.
    irqmask_db_level_high: bool,
    /// Reset the interrupt edge detector.
    irqreset: bool,
    /// Reserved.
    _rsvd1: u1 = 0,
    /// IRQ override.
    irqover: SignalOverride,
};

/// Signal override option.
pub const SignalOverride = enum(u2) {
    /// Don't override the signal.
    normal = 0,
    /// Invert the signal.
    invert = 1,
    /// Drive the signal low.
    low = 2,
    /// Drive the signal high.
    high = 3,
};

/// VOLTAGE_SELECT register
const VoltageSelect = packed struct(u32) {
    /// Voltage select per bank control.
    sel: enum(u1) {
        /// 3.3V (DVDD >= 2V5)
        v3_3 = 0,
        /// 1.8V (DVDD <= 1V8)
        v1_8 = 1,
    },
    /// Reserved.
    _rsvd: u31 = 0,
};

// =============================================================
// PADs

/// PADS GPIO<n> register.
const Pad = packed struct(u32) {
    /// Slew rate control.
    slewfast: enum(u1) {
        slow = 0,
        fast = 1,
    },
    /// Enable schmitt trigger.
    schmitt: bool,
    /// Pull down enable.
    pde: bool,
    /// Pull up enable.
    pue: bool,
    /// Drive strength.
    drive: enum(u2) {
        /// 2mA.
        ma2 = 0b00,
        /// 4mA.
        ma4 = 0b01,
        /// 8mA.
        ma8 = 0b10,
        /// 12mA.
        ma12 = 0b11,
    },
    /// Input enable.
    ie: bool,
    /// Output enable.
    od: bool,
    /// reserved.
    _rsvd: u24 = 0,
};

// =============================================================
// RIO

/// Offset to RIO_SET register from RIO register.
const rio_set_offset = 0x2000;
/// Offset to RIO_CLR register from RIO register.
const rio_clr_offset = 0x3000;

/// Controls the GPIO output drive.
const RioOut = packed struct(u32) {
    value: u32,
};
const RioOutSet = packed struct(u32) {
    value: u32,
};
const RioOutClr = packed struct(u32) {
    value: u32,
};

/// Controls the GPIO output drive enable.
const RioOe = packed struct(u32) {
    value: u32,
};
const RioOeSet = packed struct(u32) {
    value: u32,
};
const RioOeClr = packed struct(u32) {
    value: u32,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const bits = common.bits;
const mmio = common.mmio;
