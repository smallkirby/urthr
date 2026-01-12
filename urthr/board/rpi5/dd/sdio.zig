//! SDIO controller, Synopsys MSHC peripheral v1.70a.
//!
//! The peripheral is compliant with the SD Host Controller specification v4.20.

// =============================================================
// Module Definition
// =============================================================

var cfg = mmio.Module(.{ .natural = u32 }, &.{
    .{ 0x0000, Mode },
    .{ 0x0008, Local },
    .{ 0x000C, UseLocal },
    .{ 0x0010, SdDelay },
    .{ 0x0014, RxDelay },
    .{ 0x001C, Cs },
}){};

/// Offset of configuration registers within SDIO configuration block.
const cfg_regs_offset = 0x4;

// =============================================================
// API
// =============================================================

/// Source clock frequency.
const src_clk_freq = 1_000_000_000; // 1 GHz. PLL sys VCO on asic
/// Base clock frequency.
const core_clk_freq = 50_000_000; // 50 MHz. Fixed clock.
/// Cycles of source clock per one cycle of base clock.
const step = src_clk_freq / core_clk_freq;

/// Initialize SDIO controller.
pub fn init(base: usize, cfg_base: usize) void {
    // Set module bases.
    sdhc.setBase(base);
    cfg.setBase(cfg_base + cfg_regs_offset);

    // Configure GPIO pins.
    configurePins();

    // Initialize clock.
    initClock();

    // Generic SDHC initialization.
    sdhc.init();
}

/// Configure GPIO pins for SDIO1.
fn configurePins() void {
    // CLK: bias-disable
    gpio.setFunction(28, .sd1clk);
    gpio.setPull(28, .off);

    // CMD: pull-up
    gpio.setFunction(29, .sd1cmd);
    gpio.setPull(29, .up);

    //// DAT0-3: pull-up
    gpio.setFunction(30, .sd1dat0);
    gpio.setPull(30, .up);
    gpio.setFunction(31, .sd1dat1);
    gpio.setPull(31, .up);
    gpio.setFunction(32, .sd1dat2);
    gpio.setPull(32, .up);
    gpio.setFunction(33, .sd1dat3);
    gpio.setPull(33, .up);

    rtt.expectEqual(.up, gpio.getPull(29));
    rtt.expectEqual(.up, gpio.getPull(30));
    rtt.expectEqual(.up, gpio.getPull(31));
    rtt.expectEqual(.up, gpio.getPull(32));
    rtt.expectEqual(.up, gpio.getPull(33));
}

/// Initialize SDIO clock generator.
fn initClock() void {
    // Check if clocks are not running.
    rtt.expect(!isClockRunning());

    // Assert reset while we set up clkgen.
    cfg.modify(Cs, .{
        .reset = true,
    });

    // How many delay steps are available in one cycle for this source.
    const steps_value: u3 = comptime switch (step) {
        20 => 0,
        else => @compileError("Unsupported SDIO clock step value."),
    };
    cfg.write(Mode, std.mem.zeroInit(Mode, .{
        .src_sel = 2, // PLL sys VCO
        .steps = steps_value,
    }));

    // Default RX delay.
    cfg.write(RxDelay, std.mem.zeroInit(RxDelay, .{
        .overflow = .clamp,
        .map = .stretch,
        .fixed = 6,
    }));

    // Default SD delay.
    cfg.write(SdDelay, std.mem.zeroInit(SdDelay, .{
        .step = 5,
    }));

    // We select freq, we turn on TX clock, we turn on SD clk, we pick clock generator mode.
    cfg.write(UseLocal, std.mem.zeroInit(UseLocal, .{
        .freq_sel = true,
        .clk_gen_sel = true,
        .card_clk_en = true,
        .clk2card_on = true,
    }));

    // Set rate.
    const init_freq = 400_000; // 400 kHz
    const div = (core_clk_freq / init_freq) - 1;
    cfg.write(Local, std.mem.zeroInit(Local, .{
        .clk_gen_sel = true,
        .card_clk_en = true,
        .clk2card_on = true,
        .freq_sel = @as(u10, @intCast(div)),
    }));

    // De-assert reset.
    cfg.write(Cs, 0);

    // Wait for a while and check if clocks are running.
    arch.timer.spinWaitMilli(1);
    if (!isClockRunning()) {
        @panic("SDIO clock generator failed to start.");
    }
}

/// Check if SDIO clock generator is running.
fn isClockRunning() bool {
    const cs = cfg.read(Cs);
    return cs.tx_clk_running and cs.rx_clk_running and cs.sd_clk_running;
}

// =============================================================
// I/O Registers
// =============================================================

const Mode = packed struct(u32) {
    _0: u16,
    src_sel: u2,
    _1: u10,
    steps: u4,
};

const Local = packed struct(u32) {
    freq_sel: u10,
    _0: u2,
    clk_gen_sel: bool,
    _1: u3,
    card_clk_en: bool,
    card_clk_stable: bool,
    clk2card_on: bool,
    _3: u1,
    sample_cclk_sel: bool,
    _4: u2,
    tuning_cclk_update: bool,
    tuning_cclk_sel: u5,
    _5: u3,
};

const UseLocal = packed struct(u32) {
    freq_sel: bool,
    _0: u11,
    clk_gen_sel: bool,
    _1: u3,
    card_clk_en: bool,
    _2: u1,
    clk2card_on: bool,
    _3: u1,
    sample_cclk_sel: bool,
    _4: u2,
    tuning_cclk_update: bool,
    tuning_cclk_en: bool,
    _5: u7,
};

const SdDelay = packed struct(u32) {
    step: u5,
    _0: u27,
};

const RxDelay = packed struct(u32) {
    fixed: u5,
    _0: u3,
    map: enum(u2) {
        direct = 0,
        value = 1,
        stretch = 2,
    },
    _1: u2,
    overflow: enum(u2) {
        allow = 0,
        clamp = 1,
        fail = 2,
    },
    _2: u2,
    offset: u2,
    _3: u2,
    actual: u5,
    _4: u2,
    fail_actual: bool,
    bypass: bool,
    _5: u3,
};

const Cs = packed struct(u32) {
    reset: bool,
    _0: u7,
    tx_clk_running: bool,
    _1: u3,
    sd_clk_running: bool,
    _2: u3,
    rx_clk_running: bool,
    _3: u3,
    rx_del_updated: bool,
    _4: u11,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.sdio);
const common = @import("common");
const mmio = common.mmio;
const rtt = common.rtt;
const dd = @import("dd");
const sdhc = dd.sdhc;
const arch = @import("arch").impl;
const gpio = @import("gpio.zig");
