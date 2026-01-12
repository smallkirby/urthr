//! RP1 Shared SRAM.

// =============================================================
// Module Definition
// =============================================================

var sram = mmio.Module(.{ .natural = u8 }, &.{
    .{ 0x0000_FF00, mmio.Marker(.shmem) },
    .{ 0x0001_0000, mmio.Marker(.end) },
}){};

// =============================================================
// API
// =============================================================

/// RP1 FW version type.
pub const Version = u160;

/// Set the base address of the RP1 Shared SRAM.
pub fn setBase(base: usize) void {
    sram.setBase(base);
}

/// Get the RP1 firmware version.
pub fn getVersion() Version {
    var buf: [*]volatile u32 = @ptrFromInt(sram.getMarkerAddress(.shmem));

    buf[0] = @bitCast(Command{
        .op = .get_fw_version,
        .data_len = 0,
    });
    buf[1] = 0;

    // Issue command.
    mb.notify(.fw);

    // Wait for completion.
    while (!mb.checkIrq(.fw)) {
        std.atomic.spinLoopHint();
    }

    // Process response.
    if (bits.isset(buf[0], 31)) {
        @panic("RP1 FW command failed");
    }
    const version = bits.concatMany(
        u160,
        .{ buf[1], buf[2], buf[3], buf[4], buf[5] },
    );

    // Clear IRQ.
    mb.clearIrq(.fw);

    return version;
}

// =============================================================
// Registers
// =============================================================

const Command = packed struct(u32) {
    /// Size of data buffer in bytes.
    data_len: u16,
    /// Operation code.
    op: Op,
};

/// Operation codes.
const Op = enum(u16) {
    /// Get the FW version.
    get_fw_version = 0x0001,

    _,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.rp1);
const common = @import("common");
const bits = common.bits;
const mmio = common.mmio;
const mb = @import("rp1mb.zig");
