//! Display pipeline.

/// Initialize the display pipeline and register the framebuffer console.
pub fn init() urd.mem.Error!void {
    // TODO: The output is fixed to HDMI1.
    log.info("Initializing HVS.", .{});
    outer: {
        const chan_index = 1;

        const hvsbase = try urd.mem.phys.reserveAndRemap(
            "HVS",
            memmap.hvs.start,
            memmap.hvs.size(),
            null,
            .device,
        );
        rdd.hvs.setBase(hvsbase, urd.mem.dma.interface(0));

        const ddc = try urd.mem.phys.reserveAndRemap(
            "HDMI DDC",
            memmap.hdmi_ddc.start,
            memmap.hdmi_ddc.size(),
            null,
            .device,
        );
        var bsc = dd.i2c.BrcmStb.init(
            ddc + memmap.hdmi1_ddc_offset,
            .hz_97500,
        );

        rdd.hvs.init() catch |err| {
            log.err("HVS initialization failed: {t}", .{err});
            break :outer;
        };

        const mode = selectVideoMode(chan_index, bsc.adapter()) orelse {
            log.err("No supported display mode", .{});
            break :outer;
        };
        log.info("Display mode: {d}x{d} (VIC#{d})", .{ mode.hdisplay, mode.vdisplay, mode.vic });

        const chan = rdd.hvs.Channel{
            .index = chan_index,
            .width = mode.hdisplay,
            .height = mode.vdisplay,
        };

        // HDMI.
        {
            const hdmibase = try urd.mem.phys.reserveAndRemap(
                "HDMI",
                memmap.hdmi.start,
                memmap.hdmi.size(),
                null,
                .device,
            );
            const hdbase = try urd.mem.phys.reserveAndRemap(
                "HDMI HD",
                memmap.hdmi_hd.start,
                memmap.hdmi_hd.size(),
                null,
                .device,
            );
            rdd.hdmi.setBase(hdmibase, hdbase, urd.mem.dma.interface(0));
            rdd.hdmi.reset(chan.index);

            const l2base = try urd.mem.phys.reserveAndRemap(
                "L2 interrupt",
                memmap.l2intr.start,
                memmap.l2intr.size(),
                null,
                .device,
            );
            rdd.l2intr.setBase(l2base + memmap.l2intr_offset);
            initHotplug() catch |err| {
                log.err("HDMI hotplug detection setup failed: {t}", .{err});
            };
        }

        // Install the display list of the framebuffer.
        const fb = rdd.hvs.createFramebuffer(urd.mem.bin, chan, .{
            .memcpy = dmaMemcpy,
        }) catch |err| {
            log.err("HVS framebuffer creation failed: {t}", .{err});
            break :outer;
        };
        // HVS channel enable.
        rdd.hvs.initChannel(chan.index, mode.hdisplay, mode.vdisplay);

        // Pre CRTC configure.
        {
            rdd.hdmi.initClocks(mode) catch |err| {
                log.err("HDMI clock configuration failed: {t}", .{err});
            };
            rdd.hdmi.initPhy(chan.index, mode) catch |err| {
                log.err("HDMI PHY configuration failed: {t}", .{err});
            };
            rdd.hdmi.initScheduler(chan.index);
            rdd.hdmi.setTimings(chan.index, mode);
        }

        // Pixel Valve.
        pv: {
            const pvbase = try urd.mem.phys.reserveAndRemap(
                "PV",
                memmap.pv.start,
                memmap.pv.size(),
                null,
                .device,
            );
            rdd.pv.setBase(pvbase);

            rdd.pv.configure(chan.index, .hdmi1, mode) catch |err| {
                log.err("PV configuration failed: {t}", .{err});
                break :pv;
            };
            rdd.pv.enable(chan.index) catch |err| {
                log.err("PV enabling failed: {t}", .{err});
                break :pv;
            };

            // Pre CRTC enable.
            rdd.hdmi.setupCsc(chan.index, mode);
            rdd.hdmi.initFifo(chan.index);

            // CRTC enable.
            rdd.pv.enableVideo(chan.index) catch |err| {
                log.err("PV video enabling failed: {t}", .{err});
                break :pv;
            };

            // Post CRTC enable.
            rdd.hdmi.enableVideo(chan.index, mode);
            rdd.hdmi.enableHdmiMode(chan.index) catch |err| {
                log.err("HDMI mode activation failed: {t}", .{err});
            };
            rdd.hdmi.setAviPacket(chan.index, mode) catch |err| {
                log.err("HDMI AVI InfoFrame transmission failed: {t}", .{err});
            };
            rdd.hdmi.setSpdPacket(chan.index) catch |err| {
                log.err("HDMI SPD InfoFrame transmission failed: {t}", .{err});
            };
            rdd.hdmi.recenterFifo(chan.index) catch |err| {
                log.err("HDMI FIFO recentering failed: {t}", .{err});
            };
        }

        const fbcon = urd.mem.bin.create(FbConsole) catch unreachable;
        fbcon.* = FbConsole.init(fb);
        urd.console.addBackend(fbcon.interface()) catch |err| {
            log.warn("failed to add console backend: {t}", .{err});
        };
    }
}

// =============================================================
// Video

/// HDMI index of the output.
const hdmi_index = 1;

/// EDID blocks of the sink.
const Sink = struct {
    /// Base block.
    base: edid.Base,
    /// The first CTA-861 extension block.
    cta: ?edid.Cta,
};

/// Enable the HPD interrupts of the HDMI.
fn initHotplug() urd.exception.Error!void {
    rtt.expect(hdmi_index == 0 or hdmi_index == 1);

    try urd.exception.setHandler(rdd.l2intr.intid, .{
        .function = handleHotplug,
        .ctx = null,
    });

    rdd.l2intr.enable(hdmiHpdConnected(hdmi_index));
    rdd.l2intr.enable(hdmiHpdRemoved(hdmi_index));
    arch.gicv2.setTrigger(rdd.l2intr.intid, .level);
    arch.gicv2.enableIrq(rdd.l2intr.intid);
}

/// Interrupt handler of the HDMI hotplug.
fn handleHotplug(_: urd.exception.Vector, _: ?*anyopaque) void {
    if (rdd.l2intr.isPending(hdmiHpdConnected(hdmi_index))) {
        rdd.l2intr.clear(hdmiHpdConnected(hdmi_index));
        log.debug("HDMI{d} hotplug: connected", .{hdmi_index});
    }
    if (rdd.l2intr.isPending(hdmiHpdRemoved(hdmi_index))) {
        rdd.l2intr.clear(hdmiHpdRemoved(hdmi_index));
        log.debug("HDMI{d} hotplug: removed", .{hdmi_index});
    }
}

inline fn hdmiHpdConnected(comptime chan: usize) rdd.l2intr.Irq {
    return switch (chan) {
        0 => .hdmi0_hpd_connected,
        1 => .hdmi1_hpd_connected,
        else => unreachable,
    };
}
inline fn hdmiHpdRemoved(comptime chan: usize) rdd.l2intr.Irq {
    return switch (chan) {
        0 => .hdmi0_hpd_removed,
        1 => .hdmi1_hpd_removed,
        else => unreachable,
    };
}

/// Select the display mode using the information from the EDID.
///
/// The preferred timing is used if usable.
/// Otherwise, the best one is selected from all the usable modes
/// among the VIC list in the CTA-861 block, and the DTDs in both blocks.
///
/// If no candidate mode is found, falls back to VIC#16.
fn selectVideoMode(chan: usize, ddc: dd.i2c.Adapter) ?Mode {
    const fallback = Mode.fromVic(16) orelse unreachable;

    // Read EDID base block and the first CTA-861 extension block.
    var base_block: [edid.block_size]u8 = undefined;
    var cta_block: [edid.block_size]u8 = undefined;
    const sink = readEdid(
        ddc,
        &base_block,
        &cta_block,
    ) orelse return fallback;

    // Use the preferred timing in the base block.
    var base_iter = sink.base.modes();
    if (sink.base.hasPreferredTiming()) {
        if (base_iter.next()) |mode| {
            if (canOutput(chan, mode)) return mode;
        }
    }

    // Select the best mode from the remaining modes in the base block.
    var best: ?Mode = null;
    updateBestAll(chan, &best, &base_iter);
    // Select the best mode from the VIC list and the pre-defined table.
    if (sink.cta) |cta| {
        for (Mode.cta_modes) |mode| {
            if (cta.hasVic(mode.vic)) {
                updateBest(chan, &best, mode);
            }
        }
        var cta_modes = cta.modes();
        updateBestAll(chan, &best, &cta_modes);
    }

    return best orelse {
        log.warn("EDID has no supported mode", .{});
        return fallback;
    };
}

/// Consider all the remaining modes of the iterator.
fn updateBestAll(chan: usize, best: *?Mode, it: *edid.ModeIterator) void {
    while (it.next()) |mode| {
        updateBest(chan, best, mode);
    }
}

/// Update the best mode if the candidate is usable and better.
fn updateBest(chan: usize, best: *?Mode, cand: Mode) void {
    if (!canOutput(chan, cand)) return;
    if (best.*) |b| {
        if (!cand.isBetterThan(b)) return;
    }
    best.* = cand;
}

/// Check if both the PV and HDMI can output the mode.
fn canOutput(chan: usize, mode: Mode) bool {
    return rdd.pv.supports(chan, mode) and rdd.hdmi.supports(mode);
}

/// Read the base block and the first CTA-861 extension block into the buffers.
fn readEdid(
    ddc: dd.i2c.Adapter,
    base_block: *[edid.block_size]u8,
    cta_block: *[edid.block_size]u8,
) ?Sink {
    // Read the EDID base block.
    base_block.* = edid.readBlockI2c(ddc, 0) catch |err| {
        log.warn("EDID read failed: {t}", .{err});
        return null;
    };
    const base = edid.Base.parse(base_block) orelse {
        log.warn("EDID base block is invalid", .{});
        return null;
    };

    // Find the first CTA-861 extension block.
    var cta: ?edid.Cta = null;
    var index: usize = 1;
    while (index <= base.extensionCount() and cta == null) : (index += 1) {
        cta_block.* = edid.readBlockI2c(ddc, index) catch |err| {
            log.warn("EDID extension block#{d} read failed: {t}", .{ index, err });
            break;
        };
        cta = edid.Cta.parse(cta_block);
    }
    if (cta == null) {
        log.warn("No CTA-861 extension block found", .{});
    }

    return .{ .base = base, .cta = cta };
}

// =============================================================
// DMA Engine

/// DMA channel used for memcpy.
const memcpy_dma_chan = 6;

/// DMA-accelerated memcpy.
fn dmaMemcpy(_: *anyopaque, dst: usize, src: usize, len: usize) void {
    rdd.dma.memcpy(memcpy_dma_chan, src, dst, len);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.drm);
const arch = @import("arch").impl;
const common = @import("common");
const rtt = common.rtt;
const FbConsole = common.FbConsole;
const dd = @import("dd");
const edid = dd.video.edid;
const Mode = dd.video.Mode;
const memmap = @import("memmap.zig");
const rdd = @import("dd.zig");
const urd = @import("urthr");
