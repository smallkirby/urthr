//! Backend-agnostic framebuffer.

const Self = @This();

/// Optional functions for framebuffer implementation.
pub const VTable = struct {
    /// Flush the framebuffer.
    flush: ?*const fn (ctx: *anyopaque) void = null,

    /// DMA-accelerated memcpy.
    ///
    /// - `dst`: Destination physical address.
    /// - `src`: Source physical address.
    /// - `len`: Length in bytes.
    memcpy: ?*const fn (ctx: *anyopaque, dst: usize, src: usize, len: usize) void = null,
};

/// Byte order of pixel color components in memory.
pub const PixelFormat = enum {
    /// RGBX.
    rgbx8888,
    /// BGRX.
    bgrx8888,
};

/// Pointer to the framebuffer implementation.
ctx: *anyopaque,
/// Vtable.
vtable: VTable,

/// Virtual address of the framebuffer.
base: usize,
/// Physical address of the framebuffer.
///
/// Must not be null when the vtable provides a memcpy function.
phys: ?usize = null,
/// Size in bytes of the framebuffer.
size: usize,
/// Width of the framebuffer.
width: usize,
/// Height of the framebuffer.
height: usize,
/// Bytes per scanline.
pitch: usize,
/// Pixel format.
format: PixelFormat,

/// Make the written pixels visible on screen.
pub fn flush(self: *const Self) void {
    if (self.vtable.flush) |f| {
        f(self.ctx);
    }
}

/// Copy `len` bytes within the framebuffer.
///
/// `dst` and `src` are byte offsets from the beginning of the framebuffer.
/// The ranges may overlap.
pub fn copyWithin(self: *const Self, dst: usize, src: usize, len: usize) void {
    rtt.expect(dst + len <= self.size);
    rtt.expect(src + len <= self.size);

    if (self.vtable.memcpy) |f| {
        const phys = self.phys.?;
        f(self.ctx, phys + dst, phys + src, len);
    } else {
        const p: [*]u8 = @ptrFromInt(self.base);
        if (dst <= src) {
            std.mem.copyForwards(u8, p[dst..][0..len], p[src..][0..len]);
        } else {
            std.mem.copyBackwards(u8, p[dst..][0..len], p[src..][0..len]);
        }
    }
}

/// Write `data` at the byte offset `dst` from the beginning of the framebuffer.
///
/// Returns the number of bytes written.
/// Data beyond the end of the framebuffer is discarded.
///
/// No DMA support.
pub fn write(self: *const Self, dst: usize, data: []const u8) usize {
    if (dst >= self.size) return 0;

    const len = @min(data.len, self.size - dst);
    const p: [*]u8 = @ptrFromInt(self.base);
    @memcpy(p[dst..][0..len], data[0..len]);

    return len;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const rtt = @import("rtt.zig");
