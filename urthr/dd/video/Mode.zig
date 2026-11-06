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
};

/// Find the mode defined in CTA-861 by the Video Identification Code.
///
/// Returns null if the mode with the VIC is not defined.
pub fn fromVic(vic: u8) ?Self {
    for (cta_modes) |m| {
        if (m.vic == vic) return m;
    } else return null;
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

// =============================================================
// Imports
// =============================================================

const hdmi = @import("hdmi.zig");
