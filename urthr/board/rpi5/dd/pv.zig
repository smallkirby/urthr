//! BCM2712 Pixel Valve.
//!
//! ref. https://github.com/raspberrypi/linux/blob/5bd564aaa8dc4b1b8ed11733c19ec8ece63a72cc/drivers/gpu/drm/vc4/vc4_crtc.c
//! ref. https://github.com/raspberrypi/linux/blob/5bd564aaa8dc4b1b8ed11733c19ec8ece63a72cc/drivers/gpu/drm/vc4/vc4_regs.h
//!
//!
//! SPDX-License-Identifier: GPL-2.0-only
//!
//! Copyright (C) 2015 Broadcom
//!

var pvs = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x0000, Pvs },
}){};

const PvRegs = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, Control },
    .{ 0x04, VControl },
    .{ 0x08, VsyncdEven },
    .{ 0x0C, HorzA },
    .{ 0x10, HorzB },
    .{ 0x14, VertA },
    .{ 0x18, VertB },
    .{ 0x34, MuxCfg },
    .{ 0x94, PipeInitCtrl },
});
const Pvs = mmio.Array(PvRegs, 2, 0x1000);

/// Set the base address of PVs.
pub fn setBase(base: usize) void {
    pvs.setBase(base);
}

// =============================================================

pub const Error = error{
    /// No PV is fed by the HVS channel.
    NoPixelValve,
    /// The PV is not connected to the encoder.
    NoEncoder,
};

/// HW constants of PV0 and PV1.
const pv_data = [Pvs.len]PvData{
    .{
        .chan = 0,
        .fifo_depth = 64,
        .pixels_per_clock = 2,
        .encoder_types = .{ .hdmi0, null, null, null },
    },
    .{
        .chan = 1,
        .fifo_depth = 64,
        .pixels_per_clock = 2,
        .encoder_types = .{ .hdmi1, null, null, null },
    },
};

/// Encoder that a PV can output to.
pub const Encoder = enum {
    hdmi0,
    hdmi1,
};

/// Constants specific to each PV.
const PvData = struct {
    /// Index of the HVS channel that feeds this PV.
    chan: usize,
    /// Depth of the PV FIFO in bytes.
    fifo_depth: u16,
    /// Number of pixels output per clock period.
    pixels_per_clock: u16,
    /// Encoders connected to this PV.
    encoder_types: [4]?Encoder,
};

/// Check if the PV fed by the HVS channel can output the mode.
pub fn supports(chan: usize, mode: Mode) bool {
    const index = findPv(chan) orelse return false;
    const ppc = pv_data[index].pixels_per_clock;

    return mode.isValid() and
        !mode.interlaced and
        mode.hdisplay % ppc == 0 and
        (mode.hsync_start - mode.hdisplay) % ppc == 0 and // front porch
        (mode.hsync_end - mode.hsync_start) % ppc == 0 and // sync pulse width
        (mode.htotal - mode.hsync_end) % ppc == 0; // back porch
}

/// Configure the PV fed by the given HVS channel to output to the encoder.
pub fn configure(chan: usize, encoder: Encoder, mode: Mode) Error!void {
    const index = findPv(chan) orelse return Error.NoPixelValve;
    const data = pv_data[index];
    const enc_select = getEncoderSelect(data, encoder) orelse return Error.NoEncoder;
    const ppc = data.pixels_per_clock;
    const pv = pvs.sub(Pvs, index);

    // Reset the PV. It needs to be disabled before the FIFO is flushed.
    pv.modify(Control, .{ .en = false });
    pv.modify(Control, .{ .fifo_clr = true });

    pv.write(HorzA, .{
        .hsync = scale(ppc, mode.hsync_end - mode.hsync_start),
        .hbp = scale(ppc, mode.htotal - mode.hsync_end),
    });
    pv.write(HorzB, .{
        .hactive = scale(ppc, mode.hdisplay),
        .hfp = scale(ppc, mode.hsync_start - mode.hdisplay),
    });
    pv.write(VControl, .{
        .viden = false,
        .continuous = true,
        .command = false,
        .dsi = false,
        .interlace = false,
        .odd_first = false,
        .odd_delay = 0,
        .odd_timing = ppc == 1,
    });
    pv.write(VsyncdEven, .{
        .value = 0,
    });
    pv.write(VertA, .{
        .vsync = mode.vsync_end - mode.vsync_start,
        .vbp = mode.vtotal - mode.vsync_end,
    });
    pv.write(VertB, .{
        .vactive = mode.vdisplay,
        .vfp = mode.vsync_start - mode.vdisplay,
    });
    pv.write(MuxCfg, .{
        .rgb_pixel_mux_mode = .no_swap,
    });
    pv.write(PipeInitCtrl, .{
        .en = true,
        .idle = 1,
        .width = 1,
    });

    const fifo_latency_pixel = 6; // latency of the fetch of HVS in pixels
    const pixel_size = 3; // size of a pixel in bytes
    const fifo_level = data.fifo_depth - pixel_size * fifo_latency_pixel; // threshold for fill-request
    pv.write(Control, .{
        .en = false,
        .fifo_clr = true,
        .clk_select = enc_select,
        .pixel_rep = 0,
        .wait_hstart = true,
        .trigger_underflow = true,
        .clr_at_start = true,
        .fifo_level = @truncate(fifo_level >> 0),
        .format = .@"24", // RGB888
        .fifo_level_high = @truncate(fifo_level >> 6),
    });
}

/// Enable the PV fed by the given HVS channel.
pub fn enable(chan: usize) Error!void {
    const index = findPv(chan) orelse return Error.NoPixelValve;
    pvs.sub(Pvs, index).modify(Control, .{ .en = true });
}

/// Start the video output of the PV fed by the given HVS channel.
pub fn enableVideo(chan: usize) Error!void {
    const index = findPv(chan) orelse return Error.NoPixelValve;
    pvs.sub(Pvs, index).modify(VControl, .{ .viden = true });
}

/// Find the index of the PV fed by the HVS channel.
fn findPv(chan: usize) ?usize {
    for (pv_data, 0..) |d, i| {
        if (d.chan == chan) return i;
    } else return null;
}

/// Get the selector for the given encoder connected to the PV.
fn getEncoderSelect(data: PvData, encoder: Encoder) ?u2 {
    for (data.encoder_types, 0..) |e, i| {
        if (e == encoder) return @intCast(i);
    } else return null;
}

/// Divide the horizontal timing by the number of pixels per clock.
fn scale(ppc: u16, v: u16) u16 {
    rtt.expectEqual(0, v % ppc);
    return v / ppc;
}

// =============================================================
// Module Definition
// =============================================================

const Control = packed struct(u32) {
    /// Enable PV.
    en: bool,
    /// Clear FIFO.
    fifo_clr: bool,
    /// Index of the encoder connected to this PV.
    clk_select: u2,
    /// Pixel repetition - 1.
    pixel_rep: u2,
    /// Not used.
    _6: u6 = 0,
    ///
    wait_hstart: bool,
    ///
    trigger_underflow: bool,
    ///
    clr_at_start: bool,
    /// Lower bits of FIFO level.
    fifo_level: u6,
    /// Output pixel format.
    format: enum(u3) {
        /// 24 bit (RGB888)
        @"24" = 0,
        /// DSI 16-bit video mode.
        dsiv16 = 1,
        /// DSI 16-bit command mode.
        dsic16 = 2,
        /// DSI 18-bit video mode.
        dsiv18 = 3,
        /// DSI 24-bit video mode.
        dsiv24 = 4,
    },
    /// Not used.
    _24: u1 = 0,
    /// Upper bits of FIFO level.
    fifo_level_high: u2,
    /// Not used.
    _27: u5 = 0,
};

const VControl = packed struct(u32) {
    /// Video enable.
    viden: bool,
    ///
    continuous: bool,
    ///
    command: bool,
    ///
    dsi: bool,
    ///
    interlace: bool,
    ///
    odd_first: bool,
    ///
    odd_delay: u17,
    /// Not used.
    _23: u6 = 0,
    ///
    odd_timing: bool,
    /// Not used.
    _30: u2 = 0,
};

const VsyncdEven = packed struct(u32) { value: u32 };

const HorzA = packed struct(u32) {
    /// Horizontal sync width.
    hsync: u16,
    /// Horizontal back porch.
    hbp: u16,
};

const HorzB = packed struct(u32) {
    /// Active pixels of a line.
    hactive: u16,
    /// Horizontal front porch.
    hfp: u16,
};

const VertA = packed struct(u32) {
    /// Vertical sync width in lines.
    vsync: u16,
    /// Vertical back porch in lines.
    vbp: u16,
};

const VertB = packed struct(u32) {
    /// Active lines.
    vactive: u16,
    /// Vertical front porch in lines.
    vfp: u16,
};

const MuxCfg = packed struct(u32) {
    /// Not used.
    _0: u2 = 0,
    ///
    rgb_pixel_mux_mode: enum(u4) {
        no_swap = 8,
    },
    /// Not used.
    _6: u26 = 0,
};

const PipeInitCtrl = packed struct(u32) {
    /// Enable.
    en: bool,
    /// Not used.
    _1: u3 = 0,
    ///
    idle: u4,
    ///
    width: u4,
    /// Not used.
    _12: u20 = 0,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.pv);
const common = @import("common");
const dd = @import("dd");
const Mode = dd.video.Mode;
const rtt = common.rtt;
const mmio = common.mmio;
