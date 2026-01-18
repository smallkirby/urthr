//! RP1 Peripheral Ethernet Driver.
//!
//! The ethernet subsystem is implemented using the Cadence Gigabit Ethernet MAC (GEM_GXL 1p09) IP.
//!
//! This module provides HW initialization and configuration for the controller.

// =============================================================
// Module Definition
// =============================================================

/// eth_cfg module.
var cfg = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, Control },
    .{ 0x04, Status },
}){};

// =============================================================
// API
// =============================================================

/// GPIO pin number used for PHY reset.
const phy_gpio_pin = 32;

/// Set the base address of Ethernet registers.
pub fn setBase(ether: usize, config: usize) void {
    _ = ether;
    cfg.setBase(config);
}

/// Reset PHY.
pub fn resetPhy() void {
    gpio.setFunction(phy_gpio_pin, .gpio);

    // Assert reset.
    gpio.setOutput(phy_gpio_pin, false);
    // Wait for 5ms.
    arch.timer.spinWaitMilli(5);
    // De-assert reset.
    gpio.setOutput(phy_gpio_pin, true);

    // Wait for PHY to initialize.
    arch.timer.spinWaitMilli(150);
}

// =============================================================
// I/O Registers
// =============================================================

/// General Ethernet Control Register.
const Control = packed struct(u32) {
    /// tsmu master / slave - directly drives gem_tsu_ms pin
    tsu_ms: bool,
    /// tsu incremental control - directly drives gem_tsu_inc_ctrl[1:0]
    tsu_inc_ctrl: u2,
    /// Enable MAC bus errors to pass through to the fabric.
    buserr_en: bool,
    /// Memory power down.
    mem_pd: bool,
    /// Reserved.
    _rsvd: u27,
};

/// General Ethernet Status Register.
pub const Status = packed struct(u32) {
    /// rgmii link status.
    rgmii_link_status: bool,
    /// rgmii speed.
    rgmii_speed: enum(u2) {
        /// 10 Mb
        mb10 = 0,
        /// 100 Mb
        mb100 = 1,
        /// 1 Gb
        gb1 = 2,
    },
    /// rgmii duplex mode.
    rgmii_duplex: u1,
    /// Illegal AXI read address transaction.
    arlen_illegal: bool,
    /// Illegal AXI write address transaction.
    awlen_illegal: bool,
    /// Reserved.
    _rsvd: u26,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.rp5ethr);
const common = @import("common");
const mmio = common.mmio;
const arch = @import("arch").impl;
const gpio = @import("gpio.zig");
