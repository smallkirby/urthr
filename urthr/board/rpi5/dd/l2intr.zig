//! Broadcom Set Top Box Level 2 interrupt controller.
//!
//! ref. https://github.com/raspberrypi/linux/blob/5bd564aaa8dc4b1b8ed11733c19ec8ece63a72cc/drivers/irqchip/irq-brcmstb-l2.c
//!
//!
//! SPDX-License-Identifier: GPL-2.0-only
//!
//! Copyright (C) 2014-2024 Broadcom
//!

// =============================================================
// Module Definition
// =============================================================

var l2 = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, Status },
    .{ 0x08, Clear },
    .{ 0x0C, MaskStatus },
    .{ 0x10, MaskSet },
    .{ 0x14, MaskClear },
}){};

/// GIC interrupt ID of the controller.
pub const intid = 32 + 239; // +32 for SPI

/// Interrupt sources of the controller.
pub const Irq = enum(u5) {
    /// HDMI0 Hot Plug Detect connected.
    hdmi0_hpd_connected = 7,
    /// HDMI0 Hot Plug Detect removed.
    hdmi0_hpd_removed = 8,
    /// HDMI1 Hot Plug Detect connected.
    hdmi1_hpd_connected = 14,
    /// HDMI1 Hot Plug Detect removed.
    hdmi1_hpd_removed = 15,

    fn mask(self: Irq) u32 {
        return @as(u32, 1) << @backingInt(self);
    }
};

/// Set the base address of the controller.
pub fn setBase(base: usize) void {
    l2.setBase(base);
}

// =============================================================

/// Unmask the interrupt source.
///
/// Stale interrupts are discarded.
pub fn enable(irq: Irq) void {
    l2.writei(Clear, irq.mask());
    l2.writei(MaskClear, irq.mask());
}

/// Mask the source.
pub fn disable(irq: Irq) void {
    l2.writei(MaskSet, irq.mask());
}

/// Check if the source is pending.
pub fn isPending(irq: Irq) bool {
    return (l2.readi(Status) & irq.mask()) != 0;
}

/// Clear the pending interrupt of the source.
pub fn clear(irq: Irq) void {
    l2.writei(Clear, irq.mask());
}

// =============================================================
// Registers
// =============================================================

/// Status of the interrupts.
const Status = packed struct(u32) { value: u32 };

/// W1C interrupt status.
const Clear = packed struct(u32) { value: u32 };

/// Mask state.
const MaskStatus = packed struct(u32) { value: u32 };

/// W1S mask.
const MaskSet = packed struct(u32) { value: u32 };

/// W1C unmask.
const MaskClear = packed struct(u32) { value: u32 };

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const mmio = common.mmio;
