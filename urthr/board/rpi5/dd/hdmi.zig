//! BCM2712 HDMI for Gen 6D.
//!
//! ref. https://github.com/raspberrypi/linux/blob/5bd564aaa8dc4b1b8ed11733c19ec8ece63a72cc/drivers/gpu/drm/vc4/vc4_hdmi.c
//! ref. https://github.com/raspberrypi/linux/blob/5bd564aaa8dc4b1b8ed11733c19ec8ece63a72cc/drivers/gpu/drm/vc4/vc4_hdmi_phy.c
//! ref. https://github.com/raspberrypi/linux/blob/5bd564aaa8dc4b1b8ed11733c19ec8ece63a72cc/drivers/gpu/drm/vc4/vc4_hdmi_regs.h

var dvps = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x0000, Dvps },
}){};

var phys = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x0000, Phys },
}){};

var cores = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x0000, Cores },
}){};

var rms = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x0000, Rms },
}){};

var hd = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x044, VidCtl },
}){};

const DvpRegs = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x0BC, ClockStop },
});
const Dvps = mmio.Array(DvpRegs, num_hdmi, 0x5000);

const PhyRegs = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x000, ResetCtl },
    .{ 0x004, PowerupCtl },
    .{ 0x008, LaneCtl0 },
    .{ 0x00C, LaneCtl1 },
    .{ 0x010, LaneCtl2 },
    .{ 0x014, LaneCtlCk },
    .{ 0x01C, PllRefclk },
    .{ 0x028, PllPostKdiv },
    .{ 0x02C, PllVcoclkDiv },
    .{ 0x044, PllCfg },
    .{ 0x054, TmdsClkWordSel },
    .{ 0x060, PllMisc }, // 0-8
    .{ 0x190, PllResetCtl },
    .{ 0x194, PllPowerupCtl },
});
const Phys = mmio.Array(PhyRegs, num_hdmi, 0x5000);

const CoreRegs = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x07C, FifoCtl },
    .{ 0x0E8, SchedulerControl },
    .{ 0x0EC, HorzA },
    .{ 0x0F0, HorzB },
    .{ 0x0F4, VertA0 },
    .{ 0x0F8, VertB0 },
    .{ 0x100, VertA1 },
    .{ 0x104, VertB1 },
    .{ 0x114, MiscControl },
    .{ 0x18C, DeepColorConfig1 },
    .{ 0x194, GcpConfig },
    .{ 0x198, GcpWord1 },
});
const Cores = mmio.Array(CoreRegs, num_hdmi, 0x5000);

const RmRegs = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x018, RmOffset },
});
const Rms = mmio.Array(RmRegs, num_hdmi, 0x5000);

/// Number of supported HDMI interfaces.
const num_hdmi = 2;

/// Set the base address of the register blocks of HDMI0 and HDMI1.
pub fn setBase(base: usize, hd_base: usize) void {
    dvps.setBase(base + 0x1000);
    phys.setBase(base + 0x1D00);
    cores.setBase(base + 0x1400);
    rms.setBase(base + 0x2000);
    hd.setBase(hd_base + 0x0000);

    timer = arch.timer.createTimer();
    dvps.provideTimer(timer);
    phys.provideTimer(timer);
    cores.provideTimer(timer);
    rms.provideTimer(timer);
    hd.provideTimer(timer);
}

// =============================================================

pub const Error = error{
    /// The TMDS character rate is not supported.
    UnsupportedRate,
    /// Timeout while waiting for HW response.
    Timeout,
};

/// Global timer.
var timer: common.Timer = undefined;

/// Configure the FIFO of the HDMI core.
pub fn initFifo(index: usize) void {
    const core = cores.sub(Cores, index);
    core.writez(FifoCtl, .{ .master_slave_n = true });
}

/// Recenter the FIFO of the HDMI core.
pub fn recenterFifo(index: usize) Error!void {
    var core = cores.sub(Cores, index);

    const valid_write_mask = 0xEFFF;
    var drift: FifoCtl = @bitCast(core.readi(FifoCtl) & valid_write_mask);
    for (0..2) |i| {
        drift.recenter = false;
        core.write(FifoCtl, drift);
        drift.recenter = true;
        core.write(FifoCtl, drift);

        if (i == 0) arch.timer.spinWaitMilli(1);
    }

    if (!core.tryWaitFor(FifoCtl, .{ .recenter_done = true }, .ms(1))) {
        return Error.Timeout;
    }
}

/// Enable the video output of HD block?
pub fn enableVideo(index: usize, mode: pv.Mode) void {
    const stride = 4;

    hd.modifyIndexed(VidCtl, index, stride, .{
        .enable = true,
        .underflow_enable = true,
        .frame_counter_reset = true,
        .vsync_low = !mode.vsync_pos,
        .hsync_low = !mode.hsync_pos,
        .clrrgb = true,
        .blank_insert_en = true,
    });
    hd.modifyIndexed(VidCtl, index, stride, .{
        .blankpix = false,
    });
}

/// Switch the HDMI core to the HDMI mode.
pub fn enableHdmiMode(index: usize) Error!void {
    var core = cores.sub(Cores, index);

    core.modify(SchedulerControl, .{ .mode_hdmi = true });
    if (!core.tryWaitFor(SchedulerControl, .{ .hdmi_active = true }, .ms(1000))) {
        return Error.Timeout;
    }
}

/// Configure the scheduler of the HDMI core.
pub fn initScheduler(index: usize) void {
    const core = cores.sub(Cores, index);

    core.modify(SchedulerControl, .{
        .manual_format = true,
        .ignore_vsync_predicts = true,
    });
}

/// Set the timings of the HDMI core based on the given mode.
pub fn setTimings(index: usize, mode: pv.Mode) void {
    const core = cores.sub(Cores, index);
    const dvp = dvps.sub(Dvps, index);

    core.write(HorzA, .{
        .hap = @intCast(mode.hdisplay),
        .hpos = mode.hsync_pos,
        .vpos = mode.vsync_pos,
        .hfp = @intCast(mode.hsync_start - mode.hdisplay),
    });
    core.write(HorzB, .{
        .hbp = @intCast(mode.htotal - mode.hsync_end),
        .hsp = @intCast(mode.hsync_end - mode.hsync_start),
    });

    // 0 and 1 would be for interlaced mode.
    const verta = VertA{
        .vsp = @intCast(mode.vsync_end - mode.vsync_start),
        .vfp = @intCast(mode.vsync_start - mode.vdisplay),
        .val = @intCast(mode.vdisplay),
    };
    const vbp: u9 = @intCast(mode.vtotal - mode.vsync_end);
    const vertb0 = VertB{ .vbp = vbp, .vspo = 0 };
    const vertb1 = VertB{ .vbp = vbp, .vspo = @intCast(mode.htotal >> 1) };
    core.write(VertA0, .{ .value = @bitCast(verta) });
    core.write(VertA1, .{ .value = @bitCast(verta) });
    core.write(VertB0, .{ .value = @bitCast(vertb0) });
    core.write(VertB1, .{ .value = @bitCast(vertb1) });

    core.modify(DeepColorConfig1, .{
        .color_depth = 0,
        .init_pack_phase = 2,
    });
    core.modify(GcpWord1, .{
        .subpacket_byte_0 = 1 << 4, // clear AVMUTE
        .subpacket_byte_1 = 0,
    });
    core.modify(GcpConfig, .{
        .gcp_enable = true,
    });
    core.modify(MiscControl, .{
        .pixel_rep = 0,
    });

    dvp.write(ClockStop, .{
        .pixel = false,
    });
}

/// Initialize and power up the PHY and PLL.
pub fn initPhy(index: usize, mode: pv.Mode) Error!void {
    const tmds_rate = @as(u64, mode.clock) * 1000; // to Hz
    const settings = getPhySettings(tmds_rate) orelse return Error.UnsupportedRate;
    const vco = getVco(tmds_rate);
    const phy = phys.sub(Phys, index);
    const rm = rms.sub(Rms, index);

    // Reset PHY.
    phy.writei(ResetCtl, 0);
    phy.writei(PowerupCtl, 0);
    phy.writez(PllPostKdiv, .{ .bypass_en = true });

    for ([_]u32{
        0x810C_6000,
        0x00B8_C451,
        0x4640_2E31,
        0x00B8_C005,
        0x4241_0261,
        0xCC02_1001,
        0xC830_1C80,
        0xB080_4444,
        0xF80F_8000,
    }, 0..) |v, i| {
        phy.writeIndexed(PllMisc, i, @sizeOf(PllMisc), PllMisc{ .value = v });
    }
    phy.write(PllRefclk, .{
        .reffrq = oscillator_freq / 1_000_000,
        .refclk_sel_cmos = true,
    });
    phy.write(ResetCtl, .{
        .value = 0x7F,
    });
    rm.write(RmOffset, .{
        .offset = getRmOffset(vco.freq),
        .only = true,
    });
    phy.write(PllVcoclkDiv, .{
        .vcodiv = vco.div,
        .vcodiv_en = true,
    });
    phy.write(PllCfg, .{
        .pdiv = 0,
    });
    phy.writez(PllPostKdiv, .{
        .kdiv = 1,
        .clk0_sel = 2,
    });
    phy.write(LaneCtl0, .{ .value = @bitCast(settings.channel[0]) });
    phy.write(LaneCtl1, .{ .value = @bitCast(settings.channel[1]) });
    phy.write(LaneCtl2, .{ .value = @bitCast(settings.channel[2]) });
    phy.write(LaneCtlCk, .{ .value = @bitCast(settings.clock) });
    phy.write(TmdsClkWordSel, .{
        .value = if (tmds_rate >= 340_000_000) 3 else 0,
    });

    // Power up PHY and PLL.
    phy.write(PowerupCtl, .{
        .tx_0 = true,
        .tx_1 = true,
        .tx_2 = true,
        .tx_ck = true,
        .rndgen = false,
        .bias = true,
        .ldo = true,
        .bg = true,
    });
    phy.write(PllPowerupCtl, .{ .pwrup = true });

    // Release PLL from reset.
    phy.modify(PllResetCtl, .{
        .pll_resetb = false,
    });
    phy.modify(PllResetCtl, .{
        .pll_resetb = true,
    });
}

/// Oscillator frequency of the PLL in Hz.
const oscillator_freq = 54_000_000;
/// VC6 minimum frequency of the VCO in Hz.
const vco_min_freq = 8_000_000_000;
/// VC6 maximum frequency of the VCO in Hz.
const vco_max_freq = 12_000_000_000;

/// Frequency and divider of the VCO.
const Vco = struct {
    /// Frequency of VCO.
    freq: u64,
    /// Divider of VCO.
    div: u10,
};

/// Calculate the VCO frequency and divider for the TMDS rate.
fn getVco(tmds_rate: u64) Vco {
    rtt.expect(tmds_rate != 0);
    const bits_per_pixel = 10;

    var div: u64 = 0;
    while (tmds_rate * bits_per_pixel * div < vco_min_freq) {
        div += 1;
    }
    const min_div = div;

    while (tmds_rate * bits_per_pixel * (div + 1) < vco_max_freq) {
        div += 1;
    }
    const max_div = div;

    div = min_div + (max_div - min_div) / 2;
    return .{
        .freq = tmds_rate * bits_per_pixel * div,
        .div = @intCast(div),
    };
}

/// Lane settings for a range of the TMDS rate for 3 data lanes and 1 clock lane.
const PhySettings = struct {
    /// Minimum TMDS rate in Hz (inclusive).
    min_rate: u64,
    /// Maximum TMDS rate in Hz (inclusive).
    max_rate: u64,
    /// Settings of the data lanes 0-2.
    channel: [3]LaneCtl,
    /// Settings of the clock lane.
    clock: LaneCtl,

    pub fn matches(self: PhySettings, tmds_rate: u64) bool {
        return self.min_rate <= tmds_rate and tmds_rate <= self.max_rate;
    }
};

/// Lane settings for each range of the TMDS rate.
///
/// ref. https://github.com/raspberrypi/linux/blob/5bd564aaa8dc4b1b8ed11733c19ec8ece63a72cc/drivers/gpu/drm/vc4/vc4_hdmi_phy.c
const phy_settings = [_]PhySettings{
    .{
        .min_rate = 0,
        .max_rate = 222_000_000,
        .channel = .{ lane_low, lane_low, lane_low },
        .clock = lane_low,
    },
    .{
        .min_rate = 222_000_001,
        .max_rate = 297_000_000,
        .channel = .{ lane_mid, lane_mid, lane_mid },
        .clock = std.mem.zeroInit(LaneCtl, .{
            .ext_current_ctl = 12,
            .ldmos_bias_ctl = 1,
            .term_ctl = 1,
            .ext_current_src_en = true,
            .int_current_src_en = true,
            .int_current_src_hs_en = true,
        }),
    },
    .{
        .min_rate = 297_000_001,
        .max_rate = 597_000_044,
        .channel = .{ lane_high, lane_high, lane_high },
        .clock = std.mem.zeroInit(LaneCtl, .{
            .ext_current_ctl = 8,
            .slew_rate_ctl = true,
            .ldmos_bias_ctl = 1,
            .ext_current_src_hs_en = true,
            .term_ctl = 3,
            .ext_current_src_en = true,
            .int_current_src_en = true,
            .int_current_ctl = 8,
            .int_current_src_hs_en = true,
            .main_tap_current_select = 7,
        }),
    },
};

const lane_low = std.mem.zeroInit(LaneCtl, .{
    .ext_current_ctl = 8,
    .ldmos_bias_ctl = 1,
    .ext_current_src_en = true,
    .int_current_ctl = 8,
    .main_tap_current_select = 7,
});

const lane_mid = std.mem.zeroInit(LaneCtl, .{
    .ext_current_ctl = 12,
    .ldmos_bias_ctl = 1,
    .term_ctl = 1,
    .ext_current_src_en = true,
    .int_current_src_en = true,
});

const lane_high = std.mem.zeroInit(LaneCtl, .{
    .ext_current_ctl = 8,
    .slew_rate_ctl = true,
    .ldmos_bias_ctl = 1,
    .term_ctl = 3,
    .ext_current_src_en = true,
    .int_current_src_en = true,
    .int_current_ctl = 8,
    .main_tap_current_select = 7,
});

/// Get the lane settings for the TMDS rate.
fn getPhySettings(tmds_rate: u64) ?*const PhySettings {
    for (&phy_settings) |*s| {
        if (s.matches(tmds_rate)) return s;
    } else return null;
}

/// Calculate the offset of the RM from the VCO frequency.
///
/// The offset is in 9.22 fixed point format.
fn getRmOffset(vco_freq: u64) u31 {
    const offset = ((vco_freq * 2) << 22) / oscillator_freq;
    return @intCast(offset >> 2);
}

// =============================================================
// Module Definition
// =============================================================

// =============================================================
// DVP

const ClockStop = packed struct(u32) {
    /// Not used.
    _0: u1 = 0,
    /// Stop the pixel clock.
    pixel: bool,
    /// Not used.
    _2: u30 = 0,
};

// =============================================================
// PHYS

const ResetCtl = packed struct(u32) { value: u32 };

const PowerupCtl = packed struct(u32) {
    tx_0: bool,
    tx_1: bool,
    tx_2: bool,
    tx_ck: bool,
    rndgen: bool,
    _5: u1 = 0,
    bias: bool,
    ldo: bool,
    bg: bool,
    _9: u23 = 0,
};

const LaneCtl = packed struct(u32) {
    ffe_pre_tap_en: bool,
    slew_ctl_slow_driving: u2,
    slew_ctl_slow_loading: u2,
    post_tap_current_select: u3,
    main_tap_current_select: u3,
    int_current_src_hs_en: bool,
    int_current_ctl: u4,
    int_current_src_en: bool,
    ext_current_src_en: bool,
    term_ctl: u2,
    ext_current_src_hs_en: bool,
    edge_sel: bool,
    com_mode_ldmos_en: bool,
    ldmos_bias_ctl: u2,
    ffe_post_tap_en: bool,
    slew_rate_ctl: bool,
    ffe_enable: bool,
    ext_current_ctl: u4,
};

const LaneCtl0 = packed struct(u32) { value: u32 };
const LaneCtl1 = packed struct(u32) { value: u32 };
const LaneCtl2 = packed struct(u32) { value: u32 };
const LaneCtlCk = packed struct(u32) { value: u32 };

const PllRefclk = packed struct(u32) {
    /// Reference clock frequency in MHz.
    reffrq: u10,
    /// Not used.
    _10: u3 = 0,
    /// Reference clock selection is CMOS.
    refclk_sel_cmos: bool,
    /// Not used.
    _14: u18 = 0,
};

const PllPostKdiv = packed struct(u32) {
    kdiv: u2,
    clk0_sel: u2,
    bypass_en: bool,
    _5: u27 = 0,
};

const PllVcoclkDiv = packed struct(u32) {
    vcodiv: u10,
    vcodiv_en: bool,
    _11: u21 = 0,
};

const PllCfg = packed struct(u32) {
    pdiv: u4,
    _4: u28 = 0,
};

const TmdsClkWordSel = packed struct(u32) { value: u32 };

const PllMisc = packed struct(u32) { value: u32 };

const PllResetCtl = packed struct(u32) {
    /// Reset of the PLL.
    pll_resetb: bool,
    /// Reset of the post divider of the PLL.
    pllpost_resetb: bool,
    /// Not used.
    _2: u30 = 0,
};

const PllPowerupCtl = packed struct(u32) {
    pwrup: bool,
    _1: u31 = 0,
};

// =============================================================
// CORE

const FifoCtl = packed struct(u32) {
    ///
    master_slave_n: bool,
    ///
    use_full: bool,
    ///
    capture_ptr: bool,
    ///
    inv_clk_xfr: bool,
    ///
    use_pll_lock: bool,
    ///
    fifo_reset: bool,
    ///
    recenter: bool,
    ///
    on_vb: bool,
    /// Not used.
    _8: u5 = 0,
    ///
    use_empty: bool,
    /// Recentering is done.
    recenter_done: bool,
    /// Not used.
    _15: u17 = 0,
};

const SchedulerControl = packed struct(u32) {
    /// HDMI mode is selected.
    mode_hdmi: bool,
    /// HDMI mode is active.
    hdmi_active: bool,
    /// Not used.
    _2: u1 = 0,
    ///
    vert_always_keepout: bool,
    /// Not used.
    _4: u1 = 0,
    ///
    ignore_vsync_predicts: bool,
    /// Not used.
    _6: u9 = 0,
    ///
    manual_format: bool,
    /// Not used.
    _16: u16 = 0,
};

const HorzA = packed struct(u32) {
    /// Horizontal active pixels.
    hap: u14,
    /// Polarity of the horizontal sync is positive.
    hpos: bool,
    /// Polarity of the vertical sync is positive.
    vpos: bool,
    /// Horizontal sync front porch.
    hfp: u13,
    /// Not used.
    _29: u3 = 0,
};

const HorzB = packed struct(u32) {
    /// Horizontal sync pulse width.
    hsp: u11,
    /// Not used.
    _11: u5 = 0,
    /// Horizontal sync back porch.
    hbp: u11,
    /// Not used.
    _27: u5 = 0,
};

const VertA = packed struct(u32) {
    /// Vertical active lines.
    val: u13,
    /// Not used.
    _13: u3 = 0,
    /// Vertical sync front porch.
    vfp: u7,
    /// Not used.
    _23: u1 = 0,
    /// Vertical sync pulse width.
    vsp: u5,
    /// Not used.
    _29: u3 = 0,
};

const VertB = packed struct(u32) {
    /// Vertical sync back porch.
    vbp: u9,
    /// Not used.
    _9: u7 = 0,
    ///
    vspo: u14,
    /// Not used.
    _30: u2 = 0,
};

const MiscControl = packed struct(u32) {
    /// Pixel repetition - 1.
    pixel_rep: u4,
    /// Not used.
    _4: u28 = 0,
};

const DeepColorConfig1 = packed struct(u32) {
    /// Color depth signaled in GCP.
    color_depth: u4,
    /// Not used.
    _4: u4 = 0,
    ///
    init_pack_phase: u3,
    /// Not used.
    _11: u21 = 0,
};

const GcpConfig = packed struct(u32) {
    /// Not used.
    _0: u31 = 0,
    /// Send GCP.
    gcp_enable: bool,
};

const GcpWord1 = packed struct(u32) {
    /// Byte 0 of the GCP subpacket.
    subpacket_byte_0: u8,
    /// Byte 1 of the GCP subpacket.
    subpacket_byte_1: u8,
    /// Not used.
    _16: u16 = 0,
};

const VertA0 = packed struct(u32) { value: u32 };
const VertA1 = packed struct(u32) { value: u32 };
const VertB0 = packed struct(u32) { value: u32 };
const VertB1 = packed struct(u32) { value: u32 };

// =============================================================
// RM

const RmOffset = packed struct(u32) {
    offset: u31,
    only: bool,
};

// =============================================================
// HD

const VidCtl = packed struct(u32) {
    /// Not used.
    _0: u16 = 0,
    ///
    blank_insert_en: bool,
    /// Not used.
    _17: u1 = 0,
    ///
    blankpix: bool,
    /// Not used.
    _19: u4 = 0,
    ///
    clrrgb: bool,
    ///
    clrsync: bool,
    /// Not used.
    _25: u2 = 0,
    /// Polarity of the horizontal sync is negative.
    hsync_low: bool,
    /// Polarity of the vertical sync is negative.
    vsync_low: bool,
    ///
    frame_counter_reset: bool,
    ///
    underflow_enable: bool,
    ///
    enable: bool,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const arch = @import("arch").impl;
const log = std.log.scoped(.hdmi);
const common = @import("common");
const mmio = common.mmio;
const rtt = common.rtt;
const pv = @import("pv.zig");
