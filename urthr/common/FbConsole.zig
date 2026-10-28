//! Text-mode console backed by a raw pixel buffer.
//!
//! This struct implements `Console` interface.

const Self = @This();

/// State of the ANSI/VT100 escape sequence parser.
const CsiParser = struct {
    /// Maximum number of `;`-separated parameters tracked in a CSI sequence.
    const max_params = 6;

    const State = enum {
        /// Not inside an escape sequence.
        normal,
        /// Just encountered ESC and waiting for `[` to start a CSI sequence.
        esc,
        /// Inside a CSI sequence.
        csi,
        /// Just encountered `ESC (` or `ESC )` and waiting for the charset.
        charset,
        /// Inside an OSC string.
        osc,
        /// Encountered ESC inside an OSC string.
        osc_esc,
    };

    /// Parser state.
    state: State = .normal,
    /// Parameters accumulated for the CSI sequence currently being parsed.
    params: [max_params]u16 = undefined,
    /// Number of parameters accumulated so far.
    nparams: u8 = 0,
    /// Value of the CSI parameter currently being accumulated.
    cur: u16 = 0,
    /// Whether the sequence has a `?` DEC private mode prefix.
    private: bool = false,

    /// Append the currently accumulated parameter.
    fn commitParam(self: *CsiParser) void {
        if (self.nparams < max_params) {
            self.params[self.nparams] = self.cur;
            self.nparams += 1;
        }
        self.cur = 0;
    }
};

/// Framebuffer to render on.
fb: Framebuffer,

/// Cursor column in glyph units.
col: u32,
/// Cursor row in glyph units.
row: u32,
/// Number of text columns.
cols: u32,
/// Number of text rows.
rows: u32,

/// Foreground color packed as a raw pixel word.
fg: u32,
/// Background color packed as a raw pixel word.
bg: u32,
/// Whether bold output is active.
bold: bool,
/// Currently selected character set.
///
/// TODO: support G0 default and G1 alternate fonts.
charset: Charset,
/// Whether the cursor is currently rendered on screen.
cursor_shown: bool,

/// ANSI/VT100 escape sequence parser state.
csi: CsiParser,

/// Initialize the framebuffer console.
pub fn init(fb: Framebuffer) Self {
    var self = Self{
        .fb = fb,

        .col = 0,
        .row = 0,
        .cols = @intCast(fb.width / font.glyph_width),
        .rows = @intCast(fb.height / font.glyph_height),

        .fg = pack(fb.format, 0xFF, 0xFF, 0xFF),
        .bg = pack(fb.format, 0x00, 0x00, 0x00),
        .bold = false,
        .charset = .ascii,
        .cursor_shown = false,

        .csi = .{},
    };

    self.clear();

    return self;
}

/// Pack a logical RGB color into a raw pixel word.
fn pack(format: PixelFormat, r: u8, g: u8, b: u8) u32 {
    return switch (format) {
        .rgbx8888 => (@as(u32, b) << 16) | (@as(u32, g) << 8) | @as(u32, r),
        .bgrx8888 => (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b),
    };
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
    .tick = tick,
};

/// Put a single character.
fn putc(ctx: *anyopaque, c: u8) void {
    const self: *Self = @ptrCast(@alignCast(ctx));

    // Hide the cursor before touching the screen.
    self.setCursorVisible(false);
    defer self.setCursorVisible(true);

    switch (self.csi.state) {
        .normal => self.putcNormal(c),
        .esc => self.putcEsc(c),
        .csi => self.putcCsi(c),
        .charset => {
            self.charset = .from(c);
            self.csi.state = .normal;
        },
        .osc => switch (c) {
            0x07 => self.csi.state = .normal,
            0x1B => self.csi.state = .osc_esc,
            else => {}, // TODO: not handled
        },
        .osc_esc => self.csi.state = if (c == '\\') .normal else .osc,
    }
}

/// Periodic housekeeping hook.
fn tick(ctx: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.setCursorVisible(!self.cursor_shown);
}

/// Handle a byte outside of any escape sequence.
fn putcNormal(self: *Self, c: u8) void {
    switch (c) {
        0x1B => self.csi.state = .esc,
        '\n' => {
            self.col = 0;
            self.advanceRow();
        },
        '\r' => {
            self.col = 0;
        },
        0x08 => {
            if (self.col > 0) self.col -= 1;
        },
        '\t' => self.tab(),
        else => {
            self.drawGlyph(self.col, self.row, self.charset.map(c));
            self.advance();
        },
    }
}

/// Handle a byte right after ESC.
fn putcEsc(self: *Self, c: u8) void {
    switch (c) {
        // CSI
        '[' => {
            self.csi.state = .csi;
            self.csi.nparams = 0;
            self.csi.cur = 0;
            self.csi.private = false;
        },
        // Charset
        '(', ')' => self.csi.state = .charset,
        // OSC
        ']' => self.csi.state = .osc,
        // Reverse index
        'M' => {
            if (self.row > 0) self.row -= 1;
            self.csi.state = .normal;
        },
        else => self.csi.state = .normal,
    }
}

/// Character set.
const Charset = enum(u8) {
    /// DEC special graphics.
    line_drawing = '0',
    /// US-ASCII.
    ascii = 'B',

    /// Get the charset from the designator byte.
    ///
    /// Unsupported designators fall back to US-ASCII.
    fn from(designator: u8) Charset {
        return std.enums.fromInt(Charset, designator) orelse .ascii;
    }

    /// Map a byte to the character to draw in this charset.
    fn map(self: Charset, c: u8) u8 {
        return switch (self) {
            .ascii => c,

            // TODO: no corresponding glyphs.
            .line_drawing => switch (c) {
                0x71 => '-',
                0x78 => '|',
                0x6A, 0x6B, 0x6C, 0x6D, 0x74, 0x75, 0x76, 0x77, 0x6E => '+',
                else => c,
            },
        };
    }
};

/// Handle a byte inside a CSI sequence.
fn putcCsi(self: *Self, c: u8) void {
    switch (c) {
        '?' => self.csi.private = true,
        '0'...'9' => self.csi.cur = self.csi.cur *| 10 +| @as(u16, c - '0'),
        ';' => self.csi.commitParam(),
        else => {
            self.csi.commitParam();
            if (!self.csi.private) self.handleCsi(c);
            self.csi.state = .normal;
        },
    }
}

/// Dispatch a CSI sequence by its final byte.
fn handleCsi(self: *Self, final: u8) void {
    const param0: u16 = if (self.csi.nparams > 0) self.csi.params[0] else 0;
    switch (final) {
        'm' => self.applySgr(),
        'K' => self.eraseInLine(param0),
        'J' => self.eraseInDisplay(param0),
        'A' => self.moveCursor(0, -@as(i32, @max(param0, 1))),
        'B' => self.moveCursor(0, @as(i32, @max(param0, 1))),
        'C' => self.moveCursor(@as(i32, @max(param0, 1)), 0),
        'D' => self.moveCursor(-@as(i32, @max(param0, 1)), 0),
        'H', 'f' => self.setCursor(
            if (self.csi.nparams > 0) self.csi.params[0] else 1,
            if (self.csi.nparams > 1) self.csi.params[1] else 1,
        ),
        'G' => self.setCursor(@intCast(self.row + 1), @max(param0, 1)),
        'd' => self.setCursor(@max(param0, 1), @intCast(self.col + 1)),
        else => {},
    }
}

/// Move the cursor to the 1-based `(row, col)` position.
fn setCursor(self: *Self, row: u32, col: u32) void {
    self.row = @min(if (row > 0) row - 1 else 0, self.rows - 1);
    self.col = @min(if (col > 0) col - 1 else 0, self.cols - 1);
}

/// Move the cursor by a relative `(dcol, drow)` offset.
fn moveCursor(self: *Self, dcol: i32, drow: i32) void {
    const col = std.math.clamp(
        @as(i32, @intCast(self.col)) + dcol,
        0,
        @as(i32, @intCast(self.cols - 1)),
    );
    const row = std.math.clamp(
        @as(i32, @intCast(self.row)) + drow,
        0,
        @as(i32, @intCast(self.rows - 1)),
    );
    self.col = @intCast(col);
    self.row = @intCast(row);
}

/// Advance the cursor to the next tab stop.
fn tab(self: *Self) void {
    const tab_stop = 8;
    self.col = @min(util.roundup(self.col + 1, tab_stop), self.cols);
    if (self.col >= self.cols) {
        self.col = 0;
        self.advanceRow();
    }
}

/// ANSI 8-color palette (SGR 30-37 / 40-47).
const ansi_palette = [8][3]u8{
    .{ 0, 0, 0 },
    .{ 170, 0, 0 },
    .{ 0, 170, 0 },
    .{ 170, 85, 0 },
    .{ 0, 0, 170 },
    .{ 170, 0, 170 },
    .{ 0, 170, 170 },
    .{ 170, 170, 170 },
};

/// Bright ANSI 8-color palette.
const ansi_palette_bright = [8][3]u8{
    .{ 85, 85, 85 },
    .{ 255, 85, 85 },
    .{ 85, 255, 85 },
    .{ 255, 255, 85 },
    .{ 85, 85, 255 },
    .{ 255, 85, 255 },
    .{ 85, 255, 255 },
    .{ 255, 255, 255 },
};

/// Apply a SGR color.
fn applySgr(self: *Self) void {
    if (self.csi.nparams == 0) {
        self.resetColors();
        return;
    }

    for (self.csi.params[0..self.csi.nparams]) |p| {
        switch (p) {
            0 => self.resetColors(),
            1 => self.bold = true,
            22 => self.bold = false,
            30...37 => self.fg = self.ansiColor(@intCast(p - 30), self.bold),
            39 => self.fg = pack(self.fb.format, 0xFF, 0xFF, 0xFF),
            40...47 => self.bg = self.ansiColor(@intCast(p - 40), false),
            49 => self.bg = pack(self.fb.format, 0x00, 0x00, 0x00),
            90...97 => self.fg = self.ansiColor(@intCast(p - 90), true),
            100...107 => self.bg = self.ansiColor(@intCast(p - 100), true),
            else => {},
        }
    }
}

/// Pack an ANSI palette entry into a raw pixel word.
fn ansiColor(self: *Self, idx: u3, bright: bool) u32 {
    const rgb = if (bright) ansi_palette_bright[idx] else ansi_palette[idx];
    return pack(self.fb.format, rgb[0], rgb[1], rgb[2]);
}

/// Reset colors and attributes to initial state.
fn resetColors(self: *Self) void {
    self.bold = false;
    self.fg = pack(self.fb.format, 0xFF, 0xFF, 0xFF);
    self.bg = pack(self.fb.format, 0x00, 0x00, 0x00);
}

/// Erase part of the current line.
fn eraseInLine(self: *Self, mode: u16) void {
    switch (mode) {
        // Cursor to end of line.
        0 => self.clearRowRange(self.row, self.col, self.cols),
        // Start to cursor.
        1 => self.clearRowRange(self.row, 0, self.col + 1),
        // Entire line.
        2 => self.clearRowRange(self.row, 0, self.cols),
        else => {},
    }
}

/// Erase part of the screen.
fn eraseInDisplay(self: *Self, mode: u16) void {
    switch (mode) {
        // Cursor to end of screen.
        0 => {
            self.clearRowRange(self.row, self.col, self.cols);
            var r = self.row + 1;
            while (r < self.rows) : (r += 1) self.clearRow(r);
        },
        // Start to cursor.
        1 => {
            var r: u32 = 0;
            while (r < self.row) : (r += 1) self.clearRow(r);
            self.clearRowRange(self.row, 0, self.col + 1);
        },
        // Entire screen.
        2, 3 => self.clear(),
        else => {},
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
    const stride = self.fb.pitch / @sizeOf(u32);
    const pixels: [*]u32 = @ptrFromInt(self.fb.base);

    for (glyph, 0..) |row_bytes, dy| {
        var mask: u8 = 0x80;
        for (0..font.glyph_width) |dx| {
            const color = if (row_bytes[0] & mask != 0) self.fg else self.bg;
            pixels[(y0 + dy) * stride + (x0 + dx)] = color;
            mask >>= 1;
        }
    }
}

/// Show or hide the cursor at its current position.
fn setCursorVisible(self: *Self, visible: bool) void {
    if (visible == self.cursor_shown) {
        return;
    }
    self.xorCursorCell();
    self.cursor_shown = visible;
}

/// XOR-invert the pixel cell at the current cursor position.
fn xorCursorCell(self: *Self) void {
    const stride = self.fb.pitch / @sizeOf(u32);
    const x0 = self.col * font.glyph_width;
    const y0 = self.row * font.glyph_height;
    const pixels: [*]u32 = @ptrFromInt(self.fb.base);

    for (0..font.glyph_height) |dy| {
        for (0..font.glyph_width) |dx| {
            const idx = (y0 + dy) * stride + (x0 + dx);
            pixels[idx] ^= 0x00FFFFFF;
        }
    }
}

/// Advance the cursor position by one character, scrolling if necessary.
fn advance(self: *Self) void {
    self.col += 1;
    if (self.col >= self.cols) {
        self.col = 0;
        self.advanceRow();
    }
}

/// Move the cursor to the next text row, scrolling if necessary.
fn advanceRow(self: *Self) void {
    self.row += 1;
    if (self.row >= self.rows) {
        self.scrollUp();
        self.row = self.rows - 1;
    }
}

/// Scroll the framebuffer up by one text row, clearing the new bottom row.
fn scrollUp(self: *Self) void {
    const stride = self.fb.pitch / @sizeOf(u32);
    const row_pixels = stride * font.glyph_height;
    const total_pixels = stride * self.fb.height;
    const copy_count = total_pixels - row_pixels;

    self.fb.copyWithin(
        0,
        row_pixels * @sizeOf(u32),
        copy_count * @sizeOf(u32),
    );
    self.clearRow(self.rows - 1);
}

/// Clear the given text row by filling it with background color.
fn clearRow(self: *Self, text_row: u32) void {
    self.clearRowRange(text_row, 0, self.cols);
}

/// Clear columns `[col_start, col_end)` of the given text row with background color.
fn clearRowRange(self: *Self, text_row: u32, col_start: u32, col_end: u32) void {
    if (col_start >= col_end) return;

    const stride = self.fb.pitch / @sizeOf(u32);
    const y0 = text_row * font.glyph_height;
    const x_start: usize = col_start * font.glyph_width;
    const x_end: usize = @min(col_end * font.glyph_width, self.fb.width);
    const pixels: [*]u32 = @ptrFromInt(self.fb.base);
    for (0..font.glyph_height) |dy| {
        for (x_start..x_end) |dx| {
            pixels[(y0 + dy) * stride + dx] = self.bg;
        }
    }
}

/// Clear the entire framebuffer by filling it with background color.
fn clear(self: *Self) void {
    const total = (self.fb.pitch / @sizeOf(u32)) * self.fb.height;
    const pixels: [*]u32 = @ptrFromInt(self.fb.base);
    for (0..total) |i| {
        pixels[i] = self.bg;
    }
}

// =============================================================
// Tests
// =============================================================

test "pack" {
    try std.testing.expectEqual(0x00FFFFFF, pack(.rgbx8888, 0xFF, 0xFF, 0xFF));
    try std.testing.expectEqual(0x00FFFFFF, pack(.bgrx8888, 0xFF, 0xFF, 0xFF));
    try std.testing.expectEqual(0x00000000, pack(.rgbx8888, 0x00, 0x00, 0x00));
    try std.testing.expectEqual(0x00000000, pack(.bgrx8888, 0x00, 0x00, 0x00));

    try std.testing.expectEqual(0x000000FF, pack(.rgbx8888, 0xFF, 0x00, 0x00));
    try std.testing.expectEqual(0x00FF0000, pack(.bgrx8888, 0xFF, 0x00, 0x00));

    try std.testing.expectEqual(0x00FF0000, pack(.rgbx8888, 0x00, 0x00, 0xFF));
    try std.testing.expectEqual(0x000000FF, pack(.bgrx8888, 0x00, 0x00, 0xFF));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const font = @import("font8x16");
const util = @import("util.zig");
const Console = @import("Console.zig");
const Framebuffer = @import("Framebuffer.zig");
const PixelFormat = Framebuffer.PixelFormat;
