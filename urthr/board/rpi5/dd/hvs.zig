//! BCM2712 Hardware Video Scaler.
//!
//! Supports only D0 version (Gen 6D).
//!
//! ref. https://github.com/raspberrypi/linux/blob/5bd564aaa8dc4b1b8ed11733c19ec8ece63a72cc/drivers/gpu/drm/vc4/vc4_hvs.c
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
    lact: u12,
    _12: u20 = 0,
};

const DispRun = packed struct(u32) { value: u32 };

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.hvs);
const common = @import("common");
const rtt = common.rtt;
const DmaAllocator = common.mem.DmaAllocator;
const mmio = common.mmio;
const urd = @import("urthr");
const mem = urd.mem;
const vcmbox = @import("vcmbox.zig");
