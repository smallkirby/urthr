//! BCM2712 Hardware Video Scaler.
//!
//! Supports only D0 version (Gen 6D).
//!
//! ref. https://github.com/raspberrypi/linux/blob/5bd564aaa8dc4b1b8ed11733c19ec8ece63a72cc/drivers/gpu/drm/vc4/vc4_hvs.c
//! ref. https://github.com/raspberrypi/linux/blob/5bd564aaa8dc4b1b8ed11733c19ec8ece63a72cc/drivers/gpu/drm/vc4/vc4_plane.c
//! ref. https://github.com/raspberrypi/linux/blob/5bd564aaa8dc4b1b8ed11733c19ec8ece63a72cc/drivers/gpu/drm/vc4/vc4_regs.h

var hvs = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x0000, Version },
    .{ 0x0010, CobaSize },
    .{ 0x0014, CobSize },
    .{ 0x0020, Control },
    .{ 0x0024, FetcherStatus },
    .{ 0x0028, FetchStatus },
    .{ 0x0034, DlStatus },
    .{ 0x0038, PriMap0 },
    .{ 0x003C, PriMap1 },
    .{ 0x00FC, HvsId },
    .{ 0x0100, Disps },
    .{ 0x4000, mmio.Marker(.dlist) },
}){};
const Disps = mmio.Array(DispRegs, 3, 0x40);

/// Size in bytes of dlist region.
const dlist_size = 0x4000;

/// DMA allocator.
var dma: DmaAllocator = undefined;

/// Set the base address of the HVS.
pub fn setBase(base: usize, dmaallocator: DmaAllocator) void {
    hvs.setBase(base);
    dma = dmaallocator;
}

// =============================================================

const Error = error{
    /// The device or its features are not supported.
    NotSupported,
    /// The device reported an error.
    DeviceError,
} || mem.Error;

/// Initialize HVS.
pub fn init() Error!void {
    if (hvs.read(Version).version != .d0) {
        return Error.NotSupported;
    }

    // Enable the clocks.
    for ([_]u32{ clock_core, clock_disp }) |id| {
        _ = try setClockState(id, .{
            .on = true,
            .not_exist = false,
        });
    }

    // Set clock rate to minimum.
    {
        const rate = try getClockMaxRate(clock_disp);
        log.info("Set disp clock to {d} Hz: VC reported {d} Hz", .{
            rate,
            try setClockRate(clock_disp, rate),
        });
    }

    // Check clock states.
    {
        const state = try getClockState(clock_core);
        log.info("Clock core: rate {d} Hz ({d} - {d} Hz), on={}", .{
            try getClockRate(clock_core),
            try getClockMinRate(clock_core),
            try getClockMaxRate(clock_core),
            state.on,
        });
    }
    {
        const state = try getClockState(clock_disp);
        log.info("Clock disp: rate {d} Hz ({d} - {d} Hz), on={}", .{
            try getClockRate(clock_disp),
            try getClockMinRate(clock_disp),
            try getClockMaxRate(clock_disp),
            state.on,
        });
    }
}

// =============================================================
// Framebuffer

/// Scale of the framebuffer height to the screen height.
const buffer_height_scale = 2;

/// Screen information.
const Screen = struct {
    /// Plane that reads the framebuffer.
    plane: Plane,
    /// Framebuffer memory.
    mem: DmaAllocator.DmaMemory,
};

/// Create a new framebuffer and take over the plane of the FW.
///
/// TODO: the existing framebuffer created by the FW leaks.
pub fn takeOverFramebuffer(allocator: std.mem.Allocator, vt: Framebuffer.VTable) Error!Framebuffer {
    const found = findPlane() orelse {
        log.err("No supported plane found", .{});
        return Error.NotSupported;
    };
    const width = found.width;
    const height = found.height;
    const pitch = found.pitch;
    log.info("Plane found on DISP{d}: {d}x{d} pitch={d} {t}", .{
        found.disp, width, height, pitch, found.format,
    });

    const screen = try allocator.create(Screen);
    errdefer allocator.destroy(screen);

    // Allocate the buffer for framebuffer.
    const fb_size = pitch * height * buffer_height_scale;
    const buf = try dma.allocBytes(fb_size, .wc);
    errdefer dma.freeBytes(buf);
    if ((buf.bus + buf.size - 1) >> 40 != 0) {
        log.err("Failed to allocate framebuffer within address that HVS can access.", .{});
        return Error.NotSupported;
    }

    // Inject setOrigin op to the vtable.
    var new_vt = vt;
    new_vt.setOrigin = setOrigin;
    const framebuffer: Framebuffer = .{
        .ctx = screen,
        .vtable = new_vt,
        .base = buf.cpu,
        .phys = buf.bus,
        .size = buf.size,
        .width = width,
        .height = height,
        .pitch = pitch,
        .format = found.format,
    };

    // Clear the whole buffer.
    @memset(buf.slice(u32), 0xFF00_0000); // black
    dma.syncForDevice(buf.cpu, buf.size);
    arch.barrier(.full, .release);

    // Switch to the new framebuffer.
    screen.* = .{ .plane = found, .mem = buf };
    screen.plane.setAddress(buf.bus);

    log.info("Framebuffer: bus=0x{X} size=0x{X} pitch={d} {d}x{d}", .{
        buf.bus, buf.size, pitch, width, height,
    });
    return framebuffer;
}

/// Information of a display plane.
const Plane = struct {
    /// Index of the display channel.
    disp: usize,
    /// Pixel format.
    format: Framebuffer.PixelFormat,
    /// Width of the plane.
    width: usize,
    /// Height of the plane.
    height: usize,
    /// Bytes per scanline.
    pitch: usize,
    /// Upper bits of the bus address of the current buffer.
    upper: u8,

    /// PTR0 word of the plane entry.
    ptr0: *volatile u32,
    /// PTR1 word of the plane entry.
    ptr1: *volatile u32,

    /// Set the address of the pixels that the plane reads.
    ///
    /// Note that PTR0 and PTR1 can't be updated atomically.
    fn setAddress(self: *Plane, addr: usize) void {
        const upper: u8 = @intCast(addr >> 32);
        if (upper != self.upper) {
            var ptr0: DlistPtr0 = @bitCast(self.ptr0.*);
            ptr0.upper_addr = upper;
            self.ptr0.* = @bitCast(ptr0);
            self.upper = upper;
        }
        self.ptr1.* = @truncate(addr);
    }
};

/// Find the available plane of the FW by walking the dlist of enabled display channels.
///
/// Returns the first available plane that meets our requirement.
fn findPlane() ?Plane {
    for (0..Disps.len) |i| {
        if (!isDispEnabled(i)) continue;

        var didx: usize = getDlistIndex(i);
        while (didx < dlist_size / @sizeOf(u32)) {
            const dctrl = getDlistAtAs(didx, DlistCtrl0);
            if (dctrl.end) break;
            if (dctrl.valid) {
                if (parsePlane(i, didx, dctrl)) |plane| {
                    return plane;
                }
            }

            if (dctrl.next == 0) break;
            didx += dctrl.next;
        }
    }

    return null;
}

/// Parse a plane entry that starts at the given index.
///
/// Returns null if the entry is not a plane that we can take over.
fn parsePlane(disp: usize, didx: usize, ctrl: DlistCtrl0) ?Plane {
    // Pixels must be in the raster scan order.
    if (ctrl.addr_mode != .linear) {
        return null;
    }
    // Must be supported pixel format.
    const format: Framebuffer.PixelFormat = switch (ctrl.pixel_format) {
        .rgba8888 => switch (ctrl.order_rgba) {
            .argb => .bgrx8888,
            .abgr => .rgbx8888,
            else => return null,
        },
        else => return null,
    };

    var r = DlistReader.init(didx);
    r.skip(1); // CTL0
    r.skip(1); // POS0
    r.skip(1); // CTL2
    if (!ctrl.unity) r.skip(1); // POS1
    const pos2 = r.next(DlistPos2) orelse return null;
    r.skip(1); // POS3: Context
    const ptr0 = r.nextPtr() orelse return null;
    const ptr1 = r.nextPtr() orelse return null;
    const ptr2 = r.next(DlistPtr2) orelse return null;

    const width = @as(usize, pos2.src_width) + 1;
    const height = @as(usize, pos2.src_height) + 1;
    const pitch = ptr2.pitch;
    if (pitch < width * format.bytesPerPixel()) {
        return null;
    }

    return .{
        .disp = disp,
        .format = format,
        .width = width,
        .height = height,
        .pitch = pitch,
        .ptr0 = ptr0,
        .ptr1 = ptr1,
        .upper = @as(DlistPtr0, @bitCast(ptr0.*)).upper_addr,
    };
}

/// Check if the given display channel is enabled.
fn isDispEnabled(disp_idx: usize) bool {
    rtt.expect(disp_idx < Disps.len);
    const disp = hvs.sub(Disps, disp_idx);
    return disp.read(DispControl0).enb;
}

/// Get the index of active dlist for the given display channel.
fn getDlistIndex(disp_idx: usize) usize {
    rtt.expect(disp_idx < Disps.len);
    const disp = hvs.sub(Disps, disp_idx);
    return disp.read(DispDl).lact;
}

/// Get the pointer to the dlist word at the given index.
fn getDlistPtr(didx: usize) *volatile u32 {
    return @ptrFromInt(hvs.getMarkerAddress(.dlist) + didx * @sizeOf(u32));
}

/// Get the value of dlist word at the given index as the given type.
fn getDlistAtAs(didx: usize, T: type) T {
    return @bitCast(getDlistPtr(didx).*);
}

/// Set the first line of the buffer shown on the screen.
fn setOrigin(ctx: *anyopaque, y: usize) void {
    const self: *Screen = @ptrCast(@alignCast(ctx));
    arch.barrier(.full, .release);
    self.plane.setAddress(self.mem.bus + y * self.plane.pitch);
}

// =============================================================
// Clock

/// Firmware clock ID of the HVS core clock.
const clock_core = 0x04;
/// Firmware clock ID of the HVS display clock.
const clock_disp = 0x10;

/// Get the maximum supported rate for the given clock.
fn getClockMaxRate(clock_id: u32) Error!u32 {
    return clockProperty(.get_max_clock_rate, .{ clock_id, 0 });
}

/// Get the minimum supported rate for the given clock.
fn getClockMinRate(clock_id: u32) Error!u32 {
    return clockProperty(.get_min_clock_rate, .{ clock_id, 0 });
}

/// Get the current rate for the given clock.
fn getClockRate(clock_id: u32) Error!u32 {
    return clockProperty(.get_clock_rate, .{ clock_id, 0 });
}

/// Set the rate in Hz for the given clock.
fn setClockRate(clock_id: u32, rate: u32) Error!u32 {
    return clockProperty(.set_clock_rate, .{
        clock_id, // clock id
        rate, // rate in Hz
        0, // skip setting turbo
    });
}

/// Get the current state for the given clock.
fn getClockState(clock_id: u32) Error!ClockState {
    return @bitCast(try clockProperty(.get_clock_state, .{ clock_id, 0 }));
}

/// Set the clock state for the given clock.
fn setClockState(clock_id: u32, state: ClockState) Error!ClockState {
    return @bitCast(try clockProperty(.set_clock_state, .{
        clock_id,
        @as(u32, @bitCast(state)),
    }));
}

/// Property value for clock state.
const ClockState = packed struct(u32) {
    on: bool,
    not_exist: bool,
    _2: u30 = 0,
};

/// Request a clock property to VC mailbox.
fn clockProperty(tag: vcmbox.props.Tag, req: anytype) Error!u32 {
    const res = try vcmbox.props.property(dma, tag, req);
    rtt.expectEqual(req[0], res[0]);
    return res[1];
}

// =============================================================
// Module Definition
// =============================================================

const Version = packed struct(u32) {
    version: Value,
    _8: u24,

    const Value = enum(u8) {
        c0 = 0x53,
        d0 = 0x54,
        _,
    };
};

const CobaSize = packed struct(u32) { value: u32 };
const CobSize = packed struct(u32) { value: u32 };

const Control = packed struct(u32) {
    _0: u4 = 0,
    max_reqs: u4,
    _8: u4 = 0,
    dsp1_target: u2,
    _14: u2 = 0,
    abort_on_empty: bool,
    _17: u1 = 0,
    pf_lines: u5,
    _23: u8 = 0,
    hvs_en: bool,
};

const FetcherStatus = packed struct(u32) { value: u32 };
const FetchStatus = packed struct(u32) { value: u32 };
const DlStatus = packed struct(u32) { value: u32 };
/// HVS arbiter priority.
const PriMap0 = packed struct(u32) { value: u32 };
/// HVS arbiter priority.
const PriMap1 = packed struct(u32) { value: u32 };
const HvsId = packed struct(u32) { value: u32 };

// =============================================================
// Displays

const DispRegs = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, DispControl0 },
    .{ 0x04, DispControl1 },
    .{ 0x08, DispBgnd0 },
    .{ 0x0C, DispBgnd1 },
    .{ 0x10, DispLptrs },
    .{ 0x14, DispCob },
    .{ 0x18, DispStatus },
    .{ 0x1C, DispDl },
    .{ 0x20, DispRun },
});

const DispControl0 = packed struct(u32) {
    lines: u13,
    onectx: u2,
    oneshot: bool,
    fwidth: u13,
    _29: u1 = 0,
    reset: bool,
    /// Display channel is enabled.
    enb: bool,
};

const DispControl1 = packed struct(u32) {
    intlace: bool,
    _1: u7 = 0,
    bgenb: bool,
    _9: u23 = 0,
};

const DispBgnd0 = packed struct(u32) { value: u32 };
const DispBgnd1 = packed struct(u32) { value: u32 };

const DispLptrs = packed struct(u32) {
    heade: u12,
    _12: u20 = 0,
};

const DispCob = packed struct(u32) {
    base: u16,
    top: u16,
};

const DispStatus = packed struct(u32) {
    yline: u13,
    mode: enum(u2) {
        disabled = 0,
        init = 1,
        run = 2,
        eof = 3,
    },
    ofield: bool,
    frcnt: u6,
    empty: bool,
    _23: u9 = 0,
};

const DispDl = packed struct(u32) {
    /// Index of active dlist of this display channel.
    lact: u12,
    /// Reserved.
    _12: u20 = 0,
};

const DispRun = packed struct(u32) { value: u32 };

// =============================================================
// dlist

/// Sequential reader of the words in a dlist entry.
const DlistReader = struct {
    /// Index of the next word.
    index: usize,

    fn init(didx: usize) DlistReader {
        return .{ .index = didx };
    }

    /// Skip `n` words.
    fn skip(self: *DlistReader, n: usize) void {
        self.index += n;
    }

    /// Read the next word as `T`.
    ///
    /// Returns null if the word is out of the dlist entry.
    fn next(self: *DlistReader, T: type) ?T {
        const ptr = self.nextPtr() orelse return null;
        return @bitCast(ptr.*);
    }

    /// Get the pointer to the next word.
    ///
    /// Returns null if the word is out of the dlist entry.
    fn nextPtr(self: *DlistReader) ?*volatile u32 {
        if (self.index >= dlist_size / @sizeOf(u32)) return null;
        defer self.index += 1;
        return getDlistPtr(self.index);
    }
};

const PixelFormat = enum(u5) {
    // 8 bpp
    rgb3332 = 0,
    // 16 bpp
    rgba4444 = 1,
    rgb555 = 2,
    rgba5551 = 3,
    rgb565 = 4,
    // 24 bpp
    rgb888 = 5,
    // 32 bpp
    rgba6666 = 6,
    rgba8888 = 7,
    _,
};

/// First word of dlist entry.
const DlistCtrl0 = packed struct(u32) {
    /// Layout of pixels.
    pixel_format: PixelFormat,
    ///
    scl0_mode: u3,
    ///
    scl1_mode: u3,
    /// Not used.
    _11: u2 = 0,
    /// Ordering of RGBA.
    order_rgba: enum(u2) {
        /// RGBA / XBRG
        rgba = 0,
        /// BGRA / XRBG
        bgra = 1,
        /// ARGB / XRGB
        argb = 2,
        /// ABGR / XBGR
        abgr = 3,
    },
    /// Not scaled.
    ///
    /// If set, the entry has no POS1 word.
    unity: bool,
    /// Not used.
    _16: u2 = 0,
    /// Alpha mask mode.
    alpha: enum(u2) {
        /// Use the alpha channel of each pixel.
        none = 0,
        /// Use the fixed alpha defined in CTL2.
        fixed = 3,
        _,
    },
    /// Memory layout of pixels.
    addr_mode: enum(u3) {
        /// Raster scan order
        linear = 0,
        /// Broadcom SAND128
        b128 = 1,
        /// Broadcom SAND256
        b256 = 2,
        ///
        map8 = 3,
        /// UIF tiling
        uif = 4,
        _,
    },
    ///
    rgb_trans: bool,
    /// Distance between the next dlist entry.
    next: u6,
    ///
    valid: bool,
    ///
    end: bool,
};

/// Source image size.
const DlistPos2 = packed struct(u32) {
    /// Width of the source image minus one.
    src_width: u13,
    /// Not used.
    _13: u3 = 0,
    /// Height of the source image minus one.
    src_height: u13,
    /// Not used.
    _29: u3 = 0,
};

const DlistPtr0 = packed struct(u32) {
    /// Upper 8 bits of the address of pixels.
    upper_addr: u8,
    ///
    upm_buff_size: enum(u2) {
        size2lines = 0,
        size4lines = 1,
        size8lines = 2,
        size16lines = 3,
    },
    ///
    upm_handle: u5,
    /// Not used.
    _15: u1 = 0,
    ///
    upm_base: u13,
    /// Not used.
    _29: u2 = 0,
    ///
    vflip: bool,
};

const DlistPtr2 = packed struct(u32) {
    /// Bytes per scanline.
    pitch: u17,
    ///
    _17: u15 = 0,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.hvs);
const arch = @import("arch").impl;
const common = @import("common");
const rtt = common.rtt;
const DmaAllocator = common.mem.DmaAllocator;
const Framebuffer = common.Framebuffer;
const mmio = common.mmio;
const urd = @import("urthr");
const mem = urd.mem;
const vcmbox = @import("vcmbox.zig");
