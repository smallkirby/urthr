//! Raspberry Pi 4 DMA controller.
//!
//! Note that QEMU supports only Normal DMA.
//!
//! ref. https://pip-assets.raspberrypi.com/categories/545-raspberry-pi-4-model-b/documents/RP-008248-DS-1-bcm2711-peripherals.pdf

// =============================================================
// Module Definition
// =============================================================

/// Normal DMA registers module.
const Ndma = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, ndma.Cs },
    .{ 0x04, ndma.Cbad },
    .{ 0x20, ndma.Debug },
});

/// Light DMA registers module.
const Ldma = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, dma4.Cs },
    .{ 0x04, dma4.Cbad },
    .{ 0x20, dma4.Debug },
});

/// DMA4 registers module.
const Dma4 = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, dma4.Cs },
    .{ 0x04, dma4.Cbad },
    .{ 0x0C, dma4.Debug },
});

/// DMA kinds.
const DmaType = enum {
    /// Normal DMA.
    normal,
    /// Light DMA.
    light,
    /// DMA4.
    dma4,
};

/// DMA module abstraction.
const Module = union(DmaType) {
    /// Normal DMA.
    normal: Ndma,
    /// Light DMA.
    light: Ldma,
    /// DMA4.
    dma4: Dma4,
};

/// Control block abstractin.
const ControlBlock = union(DmaType) {
    /// Normal DMA.
    normal: *ndma.ControlBlock,
    /// Light DMA.
    light: *dma4.ControlBlock,
    /// DMA4.
    dma4: *dma4.ControlBlock,

    pub fn phys(self: ControlBlock) usize {
        return switch (self) {
            inline else => |cb| @intFromPtr(mem.page.translateP(cb)),
        };
    }

    pub fn asBytes(self: ControlBlock) []u8 {
        return switch (self) {
            inline else => |cb| std.mem.asBytes(cb),
        };
    }
};

/// Global registers.
var global = mmio.Module(.{ .size = u32 }, &.{
    .{ 0xFE0, IntStatus },
    .{ 0xFF0, Enable },
}){};

/// Size in bytes of each DMA channel's register block.
const channel_size = 0x100;
/// The number of DMA channels.
///
/// It actually has 16 channels, but the last one has different base address.
/// To simplify the implementation, we assume there're only 15 channels.
const num_channels = 15;

/// The index of the first normal DMA channel.
const start_ndmachan_index = 0;
/// The index of the last normal DMA channel (inclusive).
const max_ndmachan_index = 6;
/// The number of normal DMA channels.
const num_ndmachan = max_ndmachan_index - start_ndmachan_index + 1;

/// The index of the first Light DMA channel.
const start_ldmachan_index = 7;
/// The index of the last Light DMA channel (inclusive).
const max_ldmachan_index = 10;
/// The number of Light DMA channels.
const num_ldmachan = max_ldmachan_index - start_ldmachan_index + 1;

/// The index of the first DMA4 channel.
const start_dma4chan_index = 11;
/// The index of the last DMA4 channel (inclusive).
const max_dma4chan_index = 14;
/// The number of DMA4 channels.
const num_dma4chan = max_dma4chan_index - start_dma4chan_index + 1;

/// Alignment in bytes required for DMA control blocks.
const cb_align = 32;

/// DMA channel modules.
var dmas: [num_channels]Module = undefined;
/// DMA control blocks.
///
/// Supports only one CB per channel.
var cbs: [num_channels]ControlBlock = undefined;

// =============================================================
// API
// =============================================================

/// Set the base address of the DMA controllers.
pub fn setBase(base: usize) void {
    for (0..dmas.len) |i| {
        dmas[i] = if (i <= max_ndmachan_index)
            Module{ .normal = Ndma{} }
        else if (i <= max_ldmachan_index)
            Module{ .light = Ldma{} }
        else
            Module{ .dma4 = Dma4{} };

        switch (dmas[i]) {
            inline else => |*m| m.setBase(base + i * channel_size),
        }
    }

    global.setBase(base);
}

/// Initialize the DMA controller.
pub fn init() mem.Error!void {
    // Create control blocks for each DMA channel.
    for (0..cbs.len) |i| {
        if (i <= max_ndmachan_index) {
            const cb = try mem.page.create(ndma.ControlBlock);
            cb.* = std.mem.zeroes(ndma.ControlBlock);
            cbs[i] = .{ .normal = cb };
        } else if (i <= max_ldmachan_index) {
            const cb = try mem.page.create(dma4.ControlBlock);
            cb.* = std.mem.zeroes(dma4.ControlBlock);
            cbs[i] = .{ .light = cb };
        } else {
            const cb = try mem.page.create(dma4.ControlBlock);
            cb.* = std.mem.zeroes(dma4.ControlBlock);
            cbs[i] = .{ .dma4 = cb };
        }
    }
}

/// Setup a DMA channel.
pub fn setupChannel(chan: usize) void {
    rtt.expect(chan <= num_channels);

    // Enable the channel globally.
    var map: u32 = @bitCast(global.read(Enable));
    map |= @as(u32, 1) << @as(u5, @intCast(chan));
    global.write(Enable, map);

    // Reset the DMA channel.
    switch (dmas[chan]) {
        .normal => |*dma| {
            dma.modify(ndma.Cbad, .{ .addr = 0 });
            dma.modify(ndma.Debug, .{ .reset = true });
        },
        inline else => |*dma| {
            dma.modify(dma4.Cbad, .{ .addr = 0 });
            dma.modify(dma4.Debug, .{ .reset = true });
        },
    }
}

/// Performs memory copy using DMA from DRAM to DRAM.
///
/// All the given address must be physical address.
pub fn memcpy(chan: usize, from: usize, to: usize, len: usize) void {
    rtt.expect(chan <= num_channels);

    // Setup control block.
    switch (cbs[chan]) {
        .normal => |cb| {
            cb.ti = .{
                .inten = false,
                .mode = .linear,
                .wait_resp = false,
                .dest_inc = true,
                .dest_width = .@"128",
                .dest_dreq = false,
                .dest_ignore = false,
                .src_inc = true,
                .src_width = .@"128",
                .src_dreq = false,
                .src_ignore = false,
                .burst_len = 0,
                .permap = 0,
                .waits = 0,
                .no_wide_bursts = false,
            };
            cb.src = @truncate(from);
            cb.dest = @truncate(to);
            cb.len = @truncate(len);
            cb.next_cb = 0;
        },
        inline else => |cb| {
            cb.ti = .{
                .inten = false,
                .mode = .linear,
                .wait_resp = false,
                .wait_rd_resp = false,
                .permap = 0,
                .s_dreq = false,
                .d_dreq = false,
                .s_waits = 0,
                .d_waits = 0,
            };
            cb.src = @truncate(from);
            cb.srci = .{
                .addr = @truncate(from >> 32),
                .burst_len = 0,
                .inc = true,
                .size = .@"128",
                .ignore = false,
                .stride = 0,
            };
            cb.dest = @truncate(to);
            cb.desti = .{
                .addr = @truncate(to >> 32),
                .burst_len = 0,
                .inc = true,
                .size = .@"256",
                .ignore = false,
                .stride = 0,
            };
            cb.len = @truncate(len);
            cb.next_cb = 0;
        },
    }
    sync.cleanData(cbs[chan].asBytes());

    // Start the DMA.
    switch (dmas[chan]) {
        .normal => |*dma| {
            dma.write(ndma.Cbad, ndma.Cbad{
                .addr = @intCast(cbs[chan].phys()),
            });
            dma.write(ndma.Cs, std.mem.zeroInit(ndma.Cs, .{
                .active = true,
                .wait_for_outstanding_writes = true,
                .priority = 15,
                .panic_priority = 15,
            }));
        },
        inline else => |*dma| {
            dma.write(dma4.Cbad, dma4.Cbad{
                .addr = @intCast(cbs[chan].phys()),
            });
            dma.write(dma4.Cs, std.mem.zeroInit(dma4.Cs, .{
                .active = true,
                .wait_for_outstanding_writes = true,
                .qos = 15,
                .panic_qos = 15,
            }));
        },
    }
}

// =============================================================
// Register Definitions
// =============================================================

/// Normal DMA.
const ndma = struct {
    // =============================================================
    // Register Definitions

    /// Control and Status.
    const Cs = packed struct(u32) {
        /// Activate the DMA4.
        active: bool,
        /// DMA End Flag. W1C.
        end: bool,
        /// Interrupt Status. W1C.
        int: bool,
        /// DREQ (Data Request) State. RO.
        dreq: bool,
        /// DMA Paused State. RO.
        paused: bool,
        /// DMA Paused by DREQ State. RO.
        dreq_stops_dma: bool,
        /// DMA4 is waiting for the last write to be received. RO.
        waiting_outstanding_writes: bool,
        /// Reserved.
        _7: u1 = 0,
        /// DMA Error. RO.
        err: bool,
        /// Reserved.
        _9: u7 = 0,
        /// AXI Priority Level. RW.
        priority: u4,
        /// AXI Panic Priority Level. RW.
        panic_priority: u4,
        /// Reserved.
        _24: u4 = 0,
        /// Wait for outstanding writes. RW.
        wait_for_outstanding_writes: bool,
        /// Disable debug pause signal. RW.
        disdebug: bool,
        /// Abort DMA. W1SC.
        abort: bool,
        /// Writing a 1 to this bit will cleanly halt the current DMA transfer.
        halt: bool,
    };

    /// Control Block Address.
    const Cbad = packed struct(u32) {
        /// Control Block Address. RW.
        addr: u32,
    };

    /// DMA Debug.
    const Debug = packed struct(u32) {
        /// Slave Write Response Error. RC.
        write_error: bool,
        /// FIFO Error. RC.
        fifo_error: bool,
        /// Slave Read Response Error. RC.
        read_error: bool,
        /// Slave Read Response Error During Control Block Read. RC.
        read_cb_error: bool,
        /// Reserved.
        _4: u4 = 0,
        /// Generate an interrupt if an error is detected. RW.
        int_on_error: bool,
        /// Instruct the DMA4 to HALT if it detects an error. RW.
        halt_on_error: bool,
        /// Instruct the DMA4 to ABORT if it detects an error. RW.
        abort_on_error: bool,
        /// Disable the clock gating logic. RW.
        disable_clk_gate: bool,
        /// Reserved.
        _12: u2 = 0,
        /// Read State Machine State. RO.
        r_state: u4,
        /// Write State Machine State. RO.
        w_state: u4,
        /// Reserved.
        _22: u1 = 0,
        /// DMA Reset.
        reset: bool,
        /// ID.
        id: u4,
        /// DMA Version.
        version: u4,
    };

    // =============================================================
    // Control Block.

    const ControlBlock = extern struct {
        /// Transfer Information.
        ti: TransferInfo,
        /// Source Address.
        src: u32,
        /// Destination Address.
        dest: u32,
        /// Transfer Length.
        len: u32,
        /// 2D Mode Stride.
        stride: u32,
        /// Next Control Block Address.
        next_cb: u32,
        /// Reserved.
        _reserved1: u32 = 0,
        /// Reserved.
        _reserved2: u32 = 0,
    };

    const TransferInfo = packed struct(u32) {
        /// Interrupt Enable.
        inten: bool,
        /// Mode.
        mode: enum(u1) { linear = 0, twod = 1 },
        /// Reserved.
        _2: u1 = 0,
        /// Wait for Write Response.
        wait_resp: bool,
        /// Destination Address Increment.
        dest_inc: bool,
        /// Destination Transfer Width.
        dest_width: enum(u1) { @"32" = 0, @"128" = 1 },
        /// Control Destination Writes with DREQ.
        dest_dreq: bool,
        /// Ignore Writes.
        dest_ignore: bool,
        /// Source Address Increment.
        src_inc: bool,
        /// Source Transfer Width.
        src_width: enum(u1) { @"32" = 0, @"128" = 1 },
        /// Control Source Reads with DREQ.
        src_dreq: bool,
        /// Ignore Reads.
        src_ignore: bool,
        /// Burst Transfer Length.
        burst_len: u4,
        /// Peripheral Mapping.
        permap: u5,
        /// Add Wait Cycles.
        waits: u5,
        /// Don't do wide writes as a 2 beat burst.
        no_wide_bursts: bool,
        /// Reserved.
        _27: u5 = 0,
    };
};

/// DMA4.
const dma4 = struct {
    /// Control and Status.
    const Cs = packed struct(u32) {
        /// Activate the DMA4.
        active: bool,
        /// DMA End Flag. W1C.
        end: bool,
        /// Interrupt Status. W1C.
        int: bool,
        /// DREQ (Data Request) State. RO.
        dreq: bool,
        /// DMA Read Paused State. RO.
        rd_paused: bool,
        /// DMA Write Paused State. RO.
        wr_paused: bool,
        /// DMA Paused by DREQ State. RO.
        dreq_stops_dma: bool,
        /// DMA4 is waiting for the last write to be received. RO.
        waiting_outstanding_writes: bool,
        /// Reserved.
        _8: u2 = 0,
        /// DMA Error. RO.
        err: bool,
        /// Reserved.
        _11: u5 = 0,
        /// AXI QOS Level. RW.
        qos: u4,
        /// AXI Panic QOS Level. RW.
        panic_qos: u4,
        /// Indicates the DMA4 is BUSY. RO.
        dma_busy: bool,
        /// Indicates there are outstanding AXI transfers. RO.
        outstanding_transactions: bool,
        /// Reserved.
        _26: u2 = 0,
        /// Wait for outstanding writes. RW.
        wait_for_outstanding_writes: bool,
        /// Disable debug pause signal. RW.
        disdebug: bool,
        /// Abort DMA. W1SC.
        abort: bool,
        /// Writing a 1 to this bit will cleanly halt the current DMA transfer.
        halt: bool,
    };

    /// Control Block Address.
    const Cbad = packed struct(u32) {
        /// Control Block Address. RW.
        addr: u32,
    };

    /// DMA Debug.
    const Debug = packed struct(u32) {
        /// Slave Write Response Error. RC.
        write_error: bool,
        /// FIFO Error. RC.
        fifo_error: bool,
        /// Slave Read Response Error. RC.
        read_error: bool,
        /// Slave Read Response Error During Control Block Read. RC.
        read_cb_error: bool,
        /// Reserved.
        _4: u4 = 0,
        /// Generate an interrupt if an error is detected. RW.
        int_on_error: bool,
        /// Instruct the DMA4 to HALT if it detects an error. RW.
        halt_on_error: bool,
        /// Instruct the DMA4 to ABORT if it detects an error. RW.
        abort_on_error: bool,
        /// Disable the clock gating logic. RW.
        disable_clk_gate: bool,
        /// Reserved.
        _12: u2 = 0,
        /// Read State Machine State. RO.
        r_state: u4,
        /// Write State Machine State. RO.
        w_state: u4,
        /// Reserved.
        _22: u1 = 0,
        /// DMA Reset.
        reset: bool,
        /// ID.
        id: u4,
        /// DMA Version.
        version: u4,
    };

    // =============================================================
    // Control Block.
    // =============================================================

    const ControlBlock = extern struct {
        /// Transfer Information.
        ti: TransferInfo,
        /// Source Address.
        src: u32,
        /// Source Information.
        srci: SrcInfo,
        /// Destination Address.
        dest: u32,
        /// Destination Information.
        desti: DestInfo,
        /// Transfer Length.
        len: u32,
        /// Next Control Block Address.
        next_cb: u32,
        /// Reserved.
        _reserved: u32 = 0,
    };

    const TransferInfo = packed struct(u32) {
        /// Interrupt Enable.
        inten: bool,
        /// Mode.
        mode: enum(u1) { linear = 0, twod = 1 },
        /// Wait for Write Response.
        wait_resp: bool,
        /// Wait for Read Response.
        wait_rd_resp: bool,
        /// Reserved.
        _4: u5 = 0,
        /// Peripheral Mapping.
        permap: u5,
        /// Control Source Reads with DREQ.
        s_dreq: bool,
        /// Control Destination Writes with DREQ.
        d_dreq: bool,
        /// Read Wait Cycles.
        s_waits: u8,
        /// Write Wait Cycles.
        d_waits: u8,
    };

    const SrcInfo = packed struct(u32) {
        /// High bits of the Source Address [40:32].
        addr: u8,
        /// Burst Transfer Length.
        burst_len: u4,
        /// Source Address Increment.
        inc: bool,
        /// Source Transfer Width.
        size: enum(u2) { @"32" = 0, @"64" = 1, @"128" = 2, @"256" = 3 },
        /// Ignore Source Reads.
        ignore: bool,
        /// Source Stride. Only used in 2D transfer mode.
        stride: u16,
    };

    const DestInfo = packed struct(u32) {
        /// High bits of the Destinatinon Address [40:32].
        addr: u8,
        /// Burst Transfer Length.
        burst_len: u4,
        /// Destination Address Increment.
        inc: bool,
        /// Destination Transfer Width.
        size: enum(u2) { @"32" = 0, @"64" = 1, @"128" = 2, @"256" = 3 },
        /// Ignore Destination Writes.
        ignore: bool,
        /// Destination Stride. Only used in 2D transfer mode.
        stride: u16,
    };
};

// =============================================================
// Global Registers
// =============================================================

const IntStatus = packed struct(u32) {
    /// Bitmap that indicates interrupt status of each DMA channel. RO.
    ints: u16,
    /// Reserved.
    _16: u16 = 0,
};

const Enable = packed struct(u32) {
    /// Bitmap to enable the corresponding DMA channel. RW.
    enables: u15,
    /// Reserved.
    _15: u9 = 0,
    ///
    page: u4,
    ///
    pagelite: u4,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.dma);
const Allocator = std.mem.Allocator;
const common = @import("common");
const mmio = common.mmio;
const rtt = common.rtt;
const urd = @import("urthr");
const mem = urd.mem;
const sync = @import("../sync.zig");
