//! Framebuffer character device.
//!
//! Implements `fs.File` interface.

pub const fops = fs.File.Ops{
    .open = open,
    .iterate = iterate,
    .read = read,
    .write = write,
    .ioctl = ioctl,
    .close = close,
    .poll = poll,
};

fn open(inode: *fs.Inode, _: Allocator) fs.Error!*anyopaque {
    return fs.DevFs.InodeImpl.from(inode).ctx orelse fs.Error.InvalidArgument;
}

fn read(file: *fs.File, buf: []u8, pos: usize) fs.Error!usize {
    const fb = &ctx(file).fb;
    if (pos >= fb.size) return 0;

    const len = @min(buf.len, fb.size - pos);
    const p: [*]const u8 = @ptrFromInt(fb.base);
    @memcpy(buf[0..len], p[pos..][0..len]);

    return len;
}

fn write(file: *fs.File, buf: []const u8, pos: usize) fs.Error!usize {
    const backend = ctx(file);

    const written = backend.fb.write(pos, buf);
    if (written == 0 and buf.len != 0) {
        return fs.Error.NoSpace;
    }
    urd.fb.markDirty(backend);

    return written;
}

fn ioctl(file: *fs.File, request: u64, arg: usize) fs.Error!usize {
    const fb = &ctx(file).fb;

    switch (@as(Request, @fromBackingInt(@intCast(request)))) {
        .fbioget_vscreeninfo => {
            urd.uaccess.putUser(
                VarScreenInfo,
                arg,
                .from(fb),
            ) catch return fs.Error.InvalidArgument;
        },
        .fbioget_fscreeninfo => {
            urd.uaccess.putUser(
                FixScreenInfo,
                arg,
                .from(fb),
            ) catch return fs.Error.InvalidArgument;
        },
        else => return fs.Error.Unsupported,
    }
    return 0;
}

fn poll(_: *fs.File) fs.Error!fs.PollResult {
    return .{ .events = .{
        .in = true,
        .out = true,
    } };
}

fn iterate(_: *fs.File.Iterator, _: Allocator) fs.Error!?fs.File.IterResult {
    return null;
}

fn close(_: *anyopaque, _: Allocator) void {}

// =============================================================
// Helpers
// =============================================================

inline fn ctx(file: *fs.File) *urd.fb.Backend {
    return @ptrCast(@alignCast(file.ctx));
}

// =============================================================
// ioctl
// =============================================================

const Request = enum(u64) {
    /// Get device independent changeable information.
    fbioget_vscreeninfo = 0x4600,
    /// Get device independent unchangeable information.
    fbioget_fscreeninfo = 0x4602,

    _,
};

/// Bitfield layout of a color component.
const Bitfield = extern struct {
    /// Beginning of bitfield.
    offset: u32,
    /// Length of bitfield.
    length: u32,
    /// != 0 if most significant bit is right.
    msb_right: u32 = 0,
};

/// Device independent changeable information.
const VarScreenInfo = extern struct {
    /// Visible horizontal resolution.
    xres: u32,
    /// Visible vertical resolution.
    yres: u32,
    /// Virtual horizontal resolution.
    xres_virtual: u32,
    /// Virtual vertical resolution.
    yres_virtual: u32,
    /// Horizontal offset from virtual to visible.
    xoffset: u32 = 0,
    /// Vertical offset from virtual to visible.
    yoffset: u32 = 0,
    /// Bits per pixel.
    bits_per_pixel: u32,
    /// Grayscale.
    grayscale: enum(u32) { color = 0, grayscale = 1, _ } = .color,
    /// Bitfield layout of color red.
    red: Bitfield,
    /// Bitfield layout of color green.
    green: Bitfield,
    /// Bitfield layout of color blue.
    blue: Bitfield,
    /// Bitfield layout of color transparency.
    transp: Bitfield,
    /// != 0 if non standard pixel format.
    nonstd: u32 = 0,
    ///
    activate: u32 = 0,
    /// Height of the picture in mm.
    height: u32 = std.math.maxInt(u32),
    /// Width of the picture in mm.
    width: u32 = std.math.maxInt(u32),
    /// Obsolete.
    accel_flags: u32 = 0,
    /// Pixel clock in picoseconds.
    pixclock: u32 = 0,
    /// Time from sync to picture.
    left_margin: u32 = 0,
    /// Time from picture to sync.
    right_margin: u32 = 0,
    /// Time from sync to picture.
    upper_margin: u32 = 0,
    /// Time from picture to sync.
    lower_margin: u32 = 0,
    /// Length of horizontal sync.
    hsync_len: u32 = 0,
    /// Length of vertical sync.
    vsync_len: u32 = 0,
    /// Sync flags.
    sync: u32 = 0,
    /// Video mode.
    vmode: u32 = 0,
    /// Rotation angle.
    rotate: u32 = 0,
    /// Colorspace for this framebuffer.
    colorspace: u32 = 0,
    /// Reserved for future compatibility.
    reserved: [4]u32 = @splat(0),

    fn from(fb: *const Framebuffer) VarScreenInfo {
        const rgb: [3]Bitfield = switch (fb.format) {
            .rgbx8888 => .{
                .{ .offset = 0, .length = 8 },
                .{ .offset = 8, .length = 8 },
                .{ .offset = 16, .length = 8 },
            },
            .bgrx8888 => .{
                .{ .offset = 16, .length = 8 },
                .{ .offset = 8, .length = 8 },
                .{ .offset = 0, .length = 8 },
            },
        };

        return .{
            .xres = @intCast(fb.width),
            .yres = @intCast(fb.height),
            .xres_virtual = @intCast(fb.width),
            .yres_virtual = @intCast(fb.height),
            .bits_per_pixel = 32,
            .red = rgb[0],
            .green = rgb[1],
            .blue = rgb[2],
            .transp = .{ .offset = 24, .length = 0 },
        };
    }
};

/// Device independent unchangeable information.
const FixScreenInfo = extern struct {
    /// Identification string.
    id: [16]u8,
    /// Start of framebuffer memory.
    smem_start: u64,
    /// Length of framebuffer memory.
    smem_len: u32,
    ///
    type: FbType = .packed_pixels,
    /// Interleave for interleaved planes.
    type_aux: u32 = 0,
    ///
    visual: Visual = .truecolor,
    /// Zero if no hardware panning.
    xpanstep: u16 = 0,
    /// Zero if no hardware panning.
    ypanstep: u16 = 0,
    /// Zero if no hardware ywrap.
    ywrapstep: u16 = 0,
    /// Length of a line in bytes.
    line_length: u32,
    /// Start of MMIO physical address.
    mmio_start: u64 = 0,
    /// Length of MMIO region.
    mmio_len: u32 = 0,
    // Indicate to driver which specific chip or card we have.
    accel: u32 = 0,
    ///
    capabilities: u16 = 0,
    /// Reserved for future compatibility.
    reserved: [2]u16 = @splat(0),

    const FbType = enum(u32) {
        /// Packed pixels.
        packed_pixels = 0,
        /// Non interleaved planes.
        planes = 1,
        /// Interleaved planes.
        interleaved_planes = 2,
        /// Text.
        text = 3,
        /// VGA planes.
        vga_planes = 4,
        /// Type identified by a V4L2 FOURCC.
        fourcc = 5,

        _,
    };

    const Visual = enum(u32) {
        /// Monochr. 1=Black, 0=White.
        mono01 = 0,
        /// Monochr. 0=Black, 1=White.
        mono10 = 1,
        /// True color.
        truecolor = 2,
        /// Pseudo color.
        pseudocolor = 3,
        /// Direct color.
        directcolor = 4,
        /// Static pseudo color.
        static_pseudocolor = 5,
        /// Visual identified by a V4L2 FOURCC.
        fourcc = 6,

        _,
    };

    fn from(fb: *const Framebuffer) FixScreenInfo {
        var id: [16]u8 = @splat(0);
        const name = "urthr-fb";
        @memcpy(id[0..name.len], name);

        return .{
            .id = id,
            .smem_start = fb.phys orelse 0,
            .smem_len = @intCast(fb.size),
            .line_length = @intCast(fb.pitch),
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(VarScreenInfo) == 160);
    std.debug.assert(@sizeOf(FixScreenInfo) == 80);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const Framebuffer = common.Framebuffer;
const urd = @import("urthr");
const fs = urd.fs;
