//! Text-mode console backed by a raw pixel buffer.
//!
//! This struct implements `Console` interface.

const Self = @This();

/// Virtual base address of the pixel buffer.
base: usize,
/// Bytes per scanline.
pitch: u32,
/// Framebuffer width in pixels.
width: u32,
/// Framebuffer height in pixels.
height: u32,

/// Cursor column in glyph units.
col: u32,
/// Cursor row in glyph units.
row: u32,
/// Number of text columns.
cols: u32,
/// Number of text rows.
rows: u32,

/// Foreground color (RGBX8888).
fg: u32,
/// Background color (RGBX8888).
bg: u32,

/// Initialize the framebuffer console.
///
/// - `base`: Base virtual address of the pixel buffer.
/// - `pitch`: Bytes per scanline.
/// - `width`: Framebuffer width in pixels.
/// - `height`: Framebuffer height in pixels.
pub fn init(base: usize, pitch: u32, width: u32, height: u32) Self {
    var self = Self{
        .base = base,
        .pitch = pitch,
        .width = width,
        .height = height,
        .col = 0,
        .row = 0,
        .cols = width / font.glyph_width,
        .rows = height / font.glyph_height,
        .fg = 0xFF0000FF,
        .bg = 0x00000000,
    };

    self.clear();

    return self;
}

// =============================================================
// Console interface
// =============================================================

/// Return a `Console` interface backed by this framebuffer console.
pub fn interface(self: *Self) Console {
    return .{
        .vtable = vtable,
        .ctx = self,
    };
}

const vtable = Console.Vtable{
    .putc = putc,
    .flush = flush,
};

/// Put a single character.
fn putc(ctx: *anyopaque, c: u8) void {
    const self: *Self = @ptrCast(@alignCast(ctx));

    switch (c) {
        '\n' => {
            self.col = 0;
            self.row += 1;
            if (self.row >= self.rows) {
                self.scrollUp();
                self.row = self.rows - 1;
            }
        },
        '\r' => {
            self.col = 0;
        },
        else => {
            self.drawGlyph(self.col, self.row, c);
            self.advance();
        },
    }
}

/// Ensure that all previous output has been transmitted.
fn flush(_: *anyopaque) void {
    // No-op: framebuffer writes are immediately visible.
}

// =============================================================
// Internals
// =============================================================

/// Draws a single character glyph at the given text position.
fn drawGlyph(self: *Self, col: u32, row: u32, ch: u8) void {
    const glyph = font.glyphs[ch];

    const x0 = col * font.glyph_width;
    const y0 = row * font.glyph_height;
    const stride = self.pitch / @sizeOf(u32);
    const pixels: [*]volatile u32 = @ptrFromInt(self.base);

    for (glyph, 0..) |row_bytes, dy| {
        var mask: u8 = 0x80;
        for (0..font.glyph_width) |dx| {
            const color = if (row_bytes[0] & mask != 0) self.fg else self.bg;
            pixels[(y0 + dy) * stride + (x0 + dx)] = color;
            mask >>= 1;
        }
    }
}

/// Advance the cursor position by one character, scrolling if necessary.
fn advance(self: *Self) void {
    self.col += 1;
    if (self.col >= self.cols) {
        self.col = 0;
        self.row += 1;
        if (self.row >= self.rows) {
            self.scrollUp();
            self.row = self.rows - 1;
        }
    }
}

/// Scroll the framebuffer up by one text row, clearing the new bottom row.
fn scrollUp(self: *Self) void {
    const stride = self.pitch / @sizeOf(u32);
    const row_pixels = stride * font.glyph_height;
    const total_pixels = stride * self.height;
    const copy_count = total_pixels - row_pixels;

    const p: [*]u32 = @ptrFromInt(self.base);
    std.mem.copyForwards(
        u32,
        p[0..copy_count],
        p[row_pixels .. row_pixels + copy_count],
    );

    self.clearRow(self.rows - 1);
}

/// Clear the given text row by filling it with background color.
fn clearRow(self: *Self, text_row: u32) void {
    const stride = self.pitch / @sizeOf(u32);
    const y0 = text_row * font.glyph_height;
    const pixels: [*]volatile u32 = @ptrFromInt(self.base);
    for (0..font.glyph_height) |dy| {
        for (0..self.width) |dx| {
            pixels[(y0 + dy) * stride + dx] = self.bg;
        }
    }
}

/// Clear the entire framebuffer by filling it with background color.
fn clear(self: *Self) void {
    const total = (self.pitch / @sizeOf(u32)) * self.height;
    const pixels: [*]volatile u32 = @ptrFromInt(self.base);
    for (0..total) |i| {
        pixels[i] = self.bg;
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const font = @import("font8x16");
const Console = @import("Console.zig");
