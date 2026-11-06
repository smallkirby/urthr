//! Display mode.
//!
//! Signal order: active, front porch, sync, back porch.

const Self = @This();

/// Pixel clock in kHz.
clock: u32,
/// Video Identification Code defined in CTA-861.
///
/// Zero if the mode is not defined in CTA-861.
vic: u8,
/// Picture aspect ratio.
aspect: hdmi.PictureAspect,
/// Interlaced.
interlaced: bool,

/// Horizontal display size.
hdisplay: u16,
/// Horizontal sync start.
hsync_start: u16,
/// Horizontal sync end.
hsync_end: u16,
/// Horizontal total size, including horizontal border.
htotal: u16,
/// Polarity of the horizontal sync is positive.
hsync_pos: bool,

/// Vertical display size.
vdisplay: u16,
/// Vertical sync start.
vsync_start: u16,
/// Vertical sync end.
vsync_end: u16,
/// Vertical total size, including vertical border.
vtotal: u16,
/// Polarity of the vertical sync is positive.
vsync_pos: bool,

/// Modes defined in CTA-861.
pub const cta_modes = [_]Self{
    // VESA DMT / CEA-861 640x480@60Hz
    .{
        .clock = 25_175,
        .vic = 1,
        .aspect = .@"4:3",
        .interlaced = false,
        .hsync_pos = false,
        .vsync_pos = false,
        .hdisplay = 640,
        .hsync_start = 656,
        .hsync_end = 752,
        .htotal = 800,
        .vdisplay = 480,
        .vsync_start = 490,
        .vsync_end = 492,
        .vtotal = 525,
    },
    // CEA-861 1280x720@60Hz
    .{
        .clock = 74_250,
        .vic = 4,
        .aspect = .@"16:9",
        .interlaced = false,
        .hsync_pos = true,
        .vsync_pos = true,
        .hdisplay = 1280,
        .hsync_start = 1390,
        .hsync_end = 1430,
        .htotal = 1650,
        .vdisplay = 720,
        .vsync_start = 725,
        .vsync_end = 730,
        .vtotal = 750,
    },
    // CEA-861 1920x1080@60Hz
    .{
        .clock = 148_500,
        .vic = 16,
        .aspect = .@"16:9",
        .interlaced = false,
        .hsync_pos = true,
        .vsync_pos = true,
        .hdisplay = 1920,
        .hsync_start = 2008,
        .hsync_end = 2052,
        .htotal = 2200,
        .vdisplay = 1080,
        .vsync_start = 1084,
        .vsync_end = 1089,
        .vtotal = 1125,
    },
    // CEA-861 1280x720@50Hz
    .{
        .clock = 74_250,
        .vic = 19,
        .aspect = .@"16:9",
        .interlaced = false,
        .hsync_pos = true,
        .vsync_pos = true,
        .hdisplay = 1280,
        .hsync_start = 1720,
        .hsync_end = 1760,
        .htotal = 1980,
        .vdisplay = 720,
        .vsync_start = 725,
        .vsync_end = 730,
        .vtotal = 750,
    },
    // CEA-861 1920x1080@50Hz
    .{
        .clock = 148_500,
        .vic = 31,
        .aspect = .@"16:9",
        .interlaced = false,
        .hsync_pos = true,
        .vsync_pos = true,
        .hdisplay = 1920,
        .hsync_start = 2448,
        .hsync_end = 2492,
        .htotal = 2640,
        .vdisplay = 1080,
        .vsync_start = 1084,
        .vsync_end = 1089,
        .vtotal = 1125,
    },
    // CEA-861 1920x1080@24Hz
    .{
        .clock = 74_250,
        .vic = 32,
        .aspect = .@"16:9",
        .interlaced = false,
        .hsync_pos = true,
        .vsync_pos = true,
        .hdisplay = 1920,
        .hsync_start = 2558,
        .hsync_end = 2602,
        .htotal = 2750,
        .vdisplay = 1080,
        .vsync_start = 1084,
        .vsync_end = 1089,
        .vtotal = 1125,
    },
    // CEA-861 1920x1080@25Hz
    .{
        .clock = 74_250,
        .vic = 33,
        .aspect = .@"16:9",
        .interlaced = false,
        .hsync_pos = true,
        .vsync_pos = true,
        .hdisplay = 1920,
        .hsync_start = 2448,
        .hsync_end = 2492,
        .htotal = 2640,
        .vdisplay = 1080,
        .vsync_start = 1084,
        .vsync_end = 1089,
        .vtotal = 1125,
    },
    // CEA-861 1920x1080@30Hz
    .{
        .clock = 74_250,
        .vic = 34,
        .aspect = .@"16:9",
        .interlaced = false,
        .hsync_pos = true,
        .vsync_pos = true,
        .hdisplay = 1920,
        .hsync_start = 2008,
        .hsync_end = 2052,
        .htotal = 2200,
        .vdisplay = 1080,
        .vsync_start = 1084,
        .vsync_end = 1089,
        .vtotal = 1125,
    },
};

/// Find the mode defined in CTA-861 by the Video Identification Code.
///
/// Returns null if the mode with the VIC is not defined.
pub fn fromVic(vic: u8) ?Self {
    for (cta_modes) |m| {
        if (m.vic == vic) return m;
    } else return null;
}

/// Fill the given mode with known field values defined in CTA-861.
///
/// nop if no pre-defined mode matches.
pub fn fillCtaInfo(self: *Self) void {
    for (cta_modes) |m| {
        if (!self.hasSameTimings(m)) continue;

        self.vic = m.vic;
        self.aspect = m.aspect;
        return;
    }
}

/// Check if the timings are in the order of active, front porch, sync, and back porch.
pub fn isValid(self: Self) bool {
    return self.clock != 0 and
        (0 < self.hdisplay and self.hdisplay <= self.hsync_start) and
        (self.hsync_start <= self.hsync_end and self.hsync_end <= self.htotal) and
        (0 < self.vdisplay and self.vdisplay <= self.vsync_start) and
        (self.vsync_start <= self.vsync_end and self.vsync_end <= self.vtotal);
}

/// Get the number of active pixels.
pub fn pixels(self: Self) usize {
    return @as(usize, self.hdisplay) * self.vdisplay;
}

/// Get the vertical refresh rate in Hz.
pub fn refreshRate(self: Self) u32 {
    const total = @as(u64, self.htotal) * self.vtotal;
    rtt.expect(total != 0);

    const pixel_clock = @as(u64, self.clock) * 1000;
    const hz = (pixel_clock + total / 2) / total;
    return @intCast(hz);
}

/// Check if the mode is more favorable than the other.
///
/// Prefers larger resolution, higher refresh rate, and then higher pixel clock.
pub fn isBetterThan(self: Self, other: Self) bool {
    if (self.pixels() != other.pixels()) {
        return self.pixels() > other.pixels();
    }
    if (self.refreshRate() != other.refreshRate()) {
        return self.refreshRate() > other.refreshRate();
    }
    return self.clock > other.clock;
}

/// Check if the two timings are the same, ignoring non timing fields.
fn hasSameTimings(self: Self, other: Self) bool {
    // Resolution of the pixel clock of the DTD in kHz.
    const dtd_clock_resolution = 10;

    const clock_diff = @abs(@as(i64, self.clock) - @as(i64, other.clock));
    return clock_diff <= dtd_clock_resolution and
        self.hdisplay == other.hdisplay and
        self.hsync_start == other.hsync_start and
        self.hsync_end == other.hsync_end and
        self.htotal == other.htotal and
        self.hsync_pos == other.hsync_pos and
        self.vdisplay == other.vdisplay and
        self.vsync_start == other.vsync_start and
        self.vsync_end == other.vsync_end and
        self.vtotal == other.vtotal and
        self.vsync_pos == other.vsync_pos and
        self.interlaced == other.interlaced;
}

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const rtt = common.rtt;
const hdmi = @import("hdmi.zig");
