//! BCM2712 Hardware Video Scaler.
//!
//! Supports only D0 version (Gen 6D).
//!
//! ref. https://github.com/raspberrypi/linux/blob/5bd564aaa8dc4b1b8ed11733c19ec8ece63a72cc/drivers/gpu/drm/vc4/vc4_hvs.c
//! ref. https://github.com/raspberrypi/linux/blob/5bd564aaa8dc4b1b8ed11733c19ec8ece63a72cc/drivers/gpu/drm/vc4/vc4_plane.c
//! ref. https://github.com/raspberrypi/linux/blob/5bd564aaa8dc4b1b8ed11733c19ec8ece63a72cc/drivers/gpu/drm/vc4/vc4_regs.h
//!
//!
//! SPDX-License-Identifier: GPL-2.0-only
//!
//! Copyright (C) 2015 Broadcom
//!

var hvs = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x0000, Version },
    .{ 0x0004, CxmSize },
    .{ 0x0008, LbmSize },
    .{ 0x000C, UbmSize },
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
const Disps = mmio.Array(DispRegs, 3, 0x40);

/// Size in bytes of dlist region.
const dlist_size = 0x4000;
/// Number of words at the beginning of dlist memory owned by FW.
const dlist_reserved_words = 32;
/// Unit size in bytes of UPM.
const upm_unit = 256;

/// UPM handle type.
const UpmHandle = u5;
/// Address type of UPM.
const UpmAddress = u13;

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

/// Resources of the HVS.
const Resources = struct {
    /// dlist memory in words.
    dlist: RangeAllocator(dlist_size / @sizeOf(u32)),
    /// Unified Pre-Fetcher memory in `upm_unit` bytes.
    upm: RangeAllocator(1 << @bitSizeOf(UpmAddress)),
    /// UPM handles.
    upm_handles: RangeAllocator(upm_handles_capacity),

    /// The number of available UPM handles.
    const upm_handles_capacity = 1 << @bitSizeOf(UpmHandle);
};

/// Resources of the HVS.
var resources: Resources = undefined;
/// DMA allocator.
var dma: DmaAllocator = undefined;

/// Initialize HVS.
pub fn init() Error!void {
    if (hvs.read(Version).version != .d0) {
        return Error.NotSupported;
    }

    // Enable the clocks.
    for ([_]ClockId{ .core, .disp }) |id| {
        _ = try props.setClockState(dma, id, .{
            .on = true,
            .not_exist = false,
        });
    }

    // Set clock rate to maximum.
    {
        const rate = try props.getClockMaxRate(dma, .disp);
        log.info("Set disp clock to {d} Hz: VC reported {d} Hz", .{
            rate,
            try props.setClockRate(dma, .disp, rate),
        });
    }

    // Check clock states.
    {
        const state = try props.getClockState(dma, .core);
        log.info("Clock core: rate {d} Hz ({d} - {d} Hz), on={}", .{
            try props.getClockRate(dma, .core),
            try props.getClockMinRate(dma, .core),
            try props.getClockMaxRate(dma, .core),
            state.on,
        });
    }
    {
        const state = try props.getClockState(dma, .disp);
        log.info("Clock disp: rate {d} Hz ({d} - {d} Hz), on={}", .{
            try props.getClockRate(dma, .disp),
            try props.getClockMinRate(dma, .disp),
            try props.getClockMaxRate(dma, .disp),
            state.on,
        });
    }

    // Meaning of most of fields are unknown...
    hvs.write(Control, .{
        .max_reqs = 15,
        .dsp1_target = 0,
        .abort_on_empty = false,
        .pf_lines = 8,
        .hvs_en = true,
    });

    // Set the arbiter priority to max.
    hvs.write(PriMap0, .{ .value = 0xFFFF_FFFF });
    hvs.write(PriMap1, .{ .value = 0xFFFF_FFFF });

    // Assign Composite Output Buffer regions to each display channel.
    {
        const line_width = 3840; // line width of COB
        const gap = 16; // gap between COB regions
        const num_lines = 4;

        // DISP2 gets 1 line, DISP0 and DISP1 get 4 lines (don't know why).
        var base: u16 = 0;
        var top: u16 = line_width;
        var disp_idx: usize = Disps.len - 1;
        while (true) : (disp_idx -= 1) {
            const cob = DispCob{ .base = base, .top = top };
            hvs.sub(Disps, disp_idx).write(DispCob, cob);

            base = top + gap;
            top += line_width * num_lines;

            if (disp_idx == 0) break;
        }
    }

    // Record available resources.
    initResources();
}

/// Initialize the allocators of the HVS resources.
///
/// The dlist words used by the FW are marked as used.
fn initResources() void {
    resources = .{
        .dlist = .init(hvs.read(CxmSize).value),
        .upm = .init(hvs.read(UbmSize).value),
        .upm_handles = .init(Resources.upm_handles_capacity),
    };

    // Reserve the first words of dlist memory for FW.
    resources.dlist.reserve(0, dlist_reserved_words) catch unreachable;
    // Reserve the dlist words used by existing dlist entries.
    for (0..Disps.len) |i| {
        reserveDispResources(i);
    }

    log.debug("dlist: {d}/{d} words used, UPM: {d}/{d} units used", .{
        resources.dlist.countUsed(), resources.dlist.limit,
        resources.upm.countUsed(),   resources.upm.limit,
    });
}

/// Mark the dlist words used by the given display as used.
fn reserveDispResources(disp_idx: usize) void {
    const limit = resources.dlist.limit;
    const head: usize = hvs.sub(Disps, disp_idx).read(DispDl).lact;
    if (head >= limit) return;

    var didx = head;
    while (didx < limit) {
        const ctrl = getDlistAtAs(didx, DlistCtrl0);
        if (ctrl.end) break;
        if (ctrl.next == 0) break;
        didx += ctrl.next;
    }

    const end = @min(didx + 1, limit);
    resources.dlist.reserve(head, end - head) catch unreachable;
}

// =============================================================
// Framebuffer

/// Scale of the framebuffer height to the screen height.
const buffer_height_scale = 2;
/// Pixel format of the framebuffer.
const fb_format: Framebuffer.PixelFormat = .bgrx8888;
/// Number of lines that UPM prefetches for a plane.
const upm_buff_size: UpmLines = .size2lines;

/// Screen information.
const Screen = struct {
    /// Plane that reads the framebuffer.
    plane: Plane,
    /// Framebuffer memory.
    mem: DmaAllocator.DmaMemory,
};

/// Display channel information.
pub const Channel = struct {
    /// Index of the display channel.
    index: usize,
    /// Width of the channel in pixels.
    width: usize,
    /// Height of the channel in pixels.
    height: usize,
};

/// Create a new framebuffer and show it on the screen.
///
/// TODO: the existing framebuffer created by the FW leaks.
pub fn createFramebuffer(allocator: Allocator, chan: Channel, vt: Framebuffer.VTable) Error!Framebuffer {
    const pitch = chan.width * fb_format.bytesPerPixel();
    log.info("Display channel: DISP{d} {d}x{d}", .{
        chan.index, chan.width, chan.height,
    });

    const screen = try allocator.create(Screen);
    errdefer allocator.destroy(screen);

    // Allocate the buffer for framebuffer.
    const fb_size = pitch * chan.height * buffer_height_scale;
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
        .width = chan.width,
        .height = chan.height,
        .pitch = pitch,
        .format = fb_format,
    };

    // Clear the whole buffer.
    @memset(buf.slice(u32), 0xFF00_0000);
    dma.syncForDevice(buf.cpu, buf.size);

    // Create a plane and install it to the channel.
    screen.* = .{
        .plane = try Plane.create(chan, pitch, buf.bus),
        .mem = buf,
    };
    screen.plane.install();

    log.info("Framebuffer: bus=0x{X} size=0x{X} pitch={d} {d}x{d}", .{
        buf.bus, buf.size, pitch, chan.width, chan.height,
    });
    return framebuffer;
}

/// Select the enabled usable display channel.
///
/// The display with the largest resolution is selected.
pub fn selectChannel() ?Channel {
    var selected: ?Channel = null;
    for (0..Disps.len) |i| {
        const disp = hvs.sub(Disps, i);
        const ctrl0 = disp.read(DispControl0);
        if (!ctrl0.enb) continue;

        const chan = Channel{
            .index = i,
            .width = @as(usize, ctrl0.fwidth) + 1,
            .height = @as(usize, ctrl0.lines) + 1,
        };
        if (selected) |s| {
            if (chan.width * chan.height <= s.width * s.height) {
                continue;
            }
        }
        selected = chan;
    }

    return selected;
}

/// Display plane information.
const Plane = struct {
    /// Display channel that shows this plane.
    channel: Channel,
    /// Index of the first word of the dlist entry.
    dlist_head: usize,
    /// Bytes per scanline.
    pitch: usize,
    /// Upper bits of the bus address of the current buffer.
    upper: u8,

    /// PTR0 word of the plane entry.
    ptr0: *volatile u32,
    /// PTR1 word of the plane entry.
    ptr1: *volatile u32,

    /// Number of words of the plane entry.
    const nentry_words = 8;
    /// Number of words of dlist consumed by the plane entry.
    const dlist_words = nentry_words + 1; // +1 for END word
    /// Value of the END word.
    const end_word: u32 = 0x8000_0000;

    /// Create a plane entry in the dlist memory.
    ///
    /// `addr` is the bus address of the framebuffer.
    fn create(channel: Channel, pitch: usize, addr: usize) Error!Plane {
        // Allocate the resources.
        const dhead = try resources.dlist.alloc(dlist_words);
        errdefer resources.dlist.free(dhead, dlist_words);
        const upm_size = calcUpmSize(pitch, upm_buff_size.nlines());
        const upm_base = try resources.upm.alloc(upm_size);
        errdefer resources.upm.free(upm_base, upm_size);
        const uhandle = try resources.upm_handles.alloc(1);
        errdefer resources.upm_handles.free(uhandle, 1);

        // Construct dlist entry words.
        const ptr0 = DlistPtr0{
            .upper_addr = @intCast(addr >> 32),
            .upm_buff_size = upm_buff_size,
            .upm_handle = @intCast(uhandle),
            .upm_base = @intCast(upm_base),
            .vflip = false,
        };
        const entry = [nentry_words]u32{
            // CTL0
            @bitCast(DlistCtrl0{
                .pixel_format = .rgba8888,
                .scl0_mode = 0,
                .scl1_mode = 0,
                .order_rgba = .argb,
                .unity = true,
                .alpha = .none,
                .addr_mode = .linear,
                .rgb_trans = false,
                .next = nentry_words,
                .valid = true,
                .end = false,
            }),
            // POS0: Destination position.
            0,
            // CTL2: Alpha settings.
            @bitCast(DlistCtl2{
                .alpha = 0xFFF,
                .alpha_mode = .fixed,
            }),
            // POS2: Source dimensions.
            @bitCast(DlistPos2{
                .src_width = @intCast(channel.width - 1),
                .src_height = @intCast(channel.height - 1),
            }),
            // POS3: Context. Written by FW.
            0xC0C0_C0C0,
            // PTR0: UPM information.
            @bitCast(ptr0),
            // PTR1: Lower address of framebuffer.
            @truncate(addr),
            // PTR2: Pitch information.
            @bitCast(DlistPtr2{ .pitch = @intCast(pitch) }),
        };

        // Write the dlist entry to memory.
        const words: [*]volatile u32 = @ptrCast(getDlistPtr(dhead));
        for (entry, 0..) |w, i| words[i] = w;
        words[nentry_words] = end_word;

        return .{
            .channel = channel,
            .dlist_head = dhead,
            .pitch = pitch,
            .upper = ptr0.upper_addr,
            .ptr0 = &words[5],
            .ptr1 = &words[6],
        };
    }

    /// Install the plane entry to dlist.
    fn install(self: *const Plane) void {
        arch.barrier(.full, .release);
        hvs.sub(Disps, self.channel.index).write(DispLptrs, .{
            .heade = @intCast(self.dlist_head),
        });
    }

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

    /// Get the number of UPM units that a linear plane requires.
    ///
    /// ref. https://github.com/raspberrypi/linux/blob/5bd564aaa8dc4b1b8ed11733c19ec8ece63a72cc/drivers/gpu/drm/vc4/vc4_plane.c#L897
    fn calcUpmSize(pitch: usize, lines: usize) usize {
        const words_per_line = (pitch + 62) / 32;
        const fetch_region_size = words_per_line * 32;
        const buffer_size = fetch_region_size * lines;

        return std.mem.alignForward(usize, buffer_size, upm_unit) / upm_unit;
    }
};

/// Get the pointer to the dlist word at the given index.
fn getDlistPtr(didx: usize) *volatile u32 {
    rtt.expect(didx < dlist_size / @sizeOf(u32));
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

/// Size in words of dlist memory.
const CxmSize = packed struct(u32) { value: u32 };
/// Size of line buffer memory.
const LbmSize = packed struct(u32) { value: u32 };
/// Total size in 256 byte units of UPM memory.
const UbmSize = packed struct(u32) { value: u32 };
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

const DispControl0 = packed struct(u32) {
    /// Height of the channel in pixels - 1.
    lines: u13,
    ///
    onectx: u2,
    /// One-shot mode.
    oneshot: bool,
    /// Width of the channel in pixels - 1.
    fwidth: u13,
    /// Not used.
    _29: u1 = 0,
    /// Reset the display.
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
    /// Driver writes the dlist entry index to install dlist.
    heade: u12,
    /// Not used.
    _12: u20 = 0,
};

const DispCob = packed struct(u32) {
    /// Start of COB region this display channel uses.
    base: u16,
    /// End of COB region.
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

/// Third word of dlist entry.
const DlistCtl2 = packed struct(u32) {
    /// Not used.
    _0: u4 = 0,
    /// Fixed alpha value.
    alpha: u12,
    /// Not used.
    _16: u10 = 0,
    ///
    bfg: bool = false,
    ///
    _27: u1 = 0,
    ///
    alpha_mix: bool = false,
    ///
    alpha_premult: bool = false,
    /// Alpha mode.
    alpha_mode: enum(u2) {
        /// Use the pixel alpha value.
        pipeline = 0,
        /// Use the fixed alpha value defined in CTL2.
        fixed = 1,
        ///
        fixed_nonzero = 2,
        ///
        fixed_over_0x07 = 3,
    },
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

/// The number of lines that UPM prefetches.
const UpmLines = enum(u2) {
    /// 2 lines.
    size2lines = 0,
    /// 4 lines.
    size4lines = 1,
    /// 8 lines.
    size8lines = 2,
    /// 16 lines.
    size16lines = 3,

    pub fn nlines(self: UpmLines) usize {
        return @as(usize, 2) << @backingInt(self);
    }
};

const DlistPtr0 = packed struct(u32) {
    /// Upper 8 bits of the address of pixels.
    upper_addr: u8,
    /// Prefetch line size.
    upm_buff_size: UpmLines,
    /// UPM handle.
    upm_handle: UpmHandle,
    /// Not used.
    _15: u1 = 0,
    /// Base address in `upm_unit` bytes of UPM memory.
    upm_base: UpmAddress,
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
const Allocator = std.mem.Allocator;
const arch = @import("arch").impl;
const common = @import("common");
const rtt = common.rtt;
const DmaAllocator = common.mem.DmaAllocator;
const RangeAllocator = common.mem.RangeAllocator;
const Framebuffer = common.Framebuffer;
const mmio = common.mmio;
const urd = @import("urthr");
const mem = urd.mem;
const vcmbox = @import("vcmbox.zig");
const props = vcmbox.props;
const ClockId = props.ClockId;
