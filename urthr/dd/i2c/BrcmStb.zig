//! Broadcom STB BSC I2C controller driver.
//!
//! ref. https://github.com/raspberrypi/linux/blob/5bd564aaa8dc4b1b8ed11733c19ec8ece63a72cc/drivers/i2c/busses/i2c-brcmstb.c
//!
//!
//! SPDX-License-Identifier: GPL-2.0-only
//!
//! Copyright (C) 2014 Broadcom Corporation
//!

// =============================================================
// Module Definition
// =============================================================

const Bsc = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, ChipAddress },
    .{ 0x04, DataIn },
    .{ 0x24, CntReg },
    .{ 0x28, CtlReg },
    .{ 0x2C, IicEnable },
    .{ 0x30, DataOut },
    .{ 0x50, CtlHi },
});

/// Number of data registers.
const data_reg_num = 8;
/// Size of a data register in bytes in 32-bit mode.
const data_reg_size = 4;
/// Maximum number of bytes transferred by a single command.
const xfer_size = data_reg_num * data_reg_size;
/// Timeout of a command.
const timeout = common.Timer.TimeSlice.ms(100);

// =============================================================

const Self = @This();

/// SCL frequency in Hz.
pub const Speed = enum(u32) {
    hz_375000 = 375_000,
    hz_390000 = 390_000,
    hz_187500 = 187_500,
    hz_200000 = 200_000,
    hz_93750 = 93_750,
    hz_97500 = 97_500,
    hz_46875 = 46_875,
    hz_50000 = 50_000,

    /// SCL selector.
    fn sclSel(self: Speed) u2 {
        return switch (self) {
            .hz_375000, .hz_93750 => 0,
            .hz_390000, .hz_97500 => 1,
            .hz_187500, .hz_46875 => 2,
            .hz_200000, .hz_50000 => 3,
        };
    }

    /// Clock divider.
    fn divClk(self: Speed) bool {
        return switch (self) {
            .hz_375000, .hz_390000, .hz_187500, .hz_200000 => false,
            .hz_93750, .hz_97500, .hz_46875, .hz_50000 => true,
        };
    }
};

/// Registers of the controller.
bsc: Bsc,
/// SCL frequency.
speed: Speed,

/// Initialize the controller.
pub fn init(base: usize, speed: Speed) Self {
    var self = Self{
        .bsc = .new(base),
        .speed = speed,
    };
    self.bsc.provideTimer(arch.timer.createTimer());

    self.bsc.writez(CtlHi, .{
        .datareg_size = true,
    });
    self.bsc.writez(CtlReg, .{
        .scl_sel = speed.sclSel(),
        .div_clk = speed.divClk(),
    });

    return self;
}

/// Get the adapter interface.
pub fn adapter(self: *Self) i2c.Adapter {
    return .{
        .ptr = self,
        .vtable = &.{ .xfer = xfer },
    };
}

/// Condition flags of a command.
const Cond = struct {
    ///
    restart: bool = false,
    /// Don't issue I2C START and address.
    nostart: bool = false,
    /// Don't issue I2C STOP.
    nostop: bool = false,
};

/// Transfer the messages over the I2C bus.
fn xfer(ctx: *anyopaque, msgs: []const i2c.Msg) i2c.Error!void {
    const self: *Self = @ptrCast(@alignCast(ctx));

    for (msgs, 0..) |msg, i| {
        const is_last_msg = i == msgs.len - 1;

        self.bsc.writez(ChipAddress, .{
            .addr = (@as(u8, msg.addr) << 1) | @intFromBool(msg.dir == .read),
        });

        var rest = msg.buf;
        var first = true;
        while (rest.len != 0) : (first = false) {
            const len = @min(rest.len, xfer_size);
            const is_last = rest.len <= xfer_size;

            try self.command(msg.dir, .{
                .nostart = !first,
                .nostop = !(is_last and is_last_msg),
                .restart = is_last and !is_last_msg,
            }, rest[0..len]);

            rest = rest[len..];
        }
    }
}

/// Transfer up to `xfer_size` bytes.
fn command(self: *Self, dir: i2c.Msg.Direction, cond: Cond, buf: []u8) i2c.Error!void {
    rtt.expect(0 < buf.len and buf.len <= xfer_size);
    const bsc = &self.bsc;

    // Wait for device to be ready.
    if (!bsc.tryWaitFor(IicEnable, .{ .intrp = false }, timeout)) {
        return i2c.Error.Timeout;
    }

    // Set data transfer size.
    bsc.write(CntReg, .{
        .len = @intCast(buf.len),
    });

    // Write data.
    if (dir == .write) {
        var written: usize = 0;
        while (written < buf.len) : (written += data_reg_size) {
            var word: [data_reg_size]u8 = @splat(0);
            const n = @min(data_reg_size, buf.len - written);
            @memcpy(word[0..n], buf[written..][0..n]);
            bsc.writeIndexed(
                DataIn,
                written / data_reg_size,
                data_reg_size,
                std.mem.readInt(u32, &word, .little),
            );
        }
    }

    // Set data transfer direction and enable BSC CTL interrupt line.
    const ctl = CtlReg{
        .dtf = if (dir == .write) .write else .read,
        .scl_sel = self.speed.sclSel(),
        .int_en = true,
        .div_clk = self.speed.divClk(),
    };
    bsc.write(CtlReg, ctl);
    defer {
        bsc.writez(CntReg, .{});
        bsc.writez(IicEnable, .{});
    }

    // Initiate transfer.
    bsc.writez(IicEnable, .{
        .enable = true,
        .nostop = cond.nostop,
        .nostart = cond.nostart,
        .restart = cond.restart,
    });

    // Wait for transaction to finish or timeout.
    const done = bsc.tryWaitFor(IicEnable, .{
        .intrp = true,
    }, timeout);
    // Disable interrupt after transaction.
    bsc.write(CtlReg, .{
        .dtf = ctl.dtf,
        .scl_sel = ctl.scl_sel,
        .int_en = false,
        .div_clk = ctl.div_clk,
    });
    if (!done) return i2c.Error.Timeout;

    // Check for NACK.
    if (bsc.read(IicEnable).noack) {
        return i2c.Error.Nak;
    }

    // Read data.
    if (dir == .read) {
        var read: usize = 0;
        while (read < buf.len) : (read += data_reg_size) {
            const word = bsc.readIndexed(
                DataOut,
                read / data_reg_size,
                data_reg_size,
            ).value;

            var bytes: [data_reg_size]u8 = undefined;
            std.mem.writeInt(u32, &bytes, word, .little);
            const n = @min(data_reg_size, buf.len - read);
            @memcpy(buf[read..][0..n], bytes[0..n]);
        }
    }
}

// =============================================================
// Module Definition
// =============================================================

/// Transfer address.
const ChipAddress = packed struct(u32) {
    /// 8-bit target address including the R/W bit.
    addr: u8,
    /// Not used.
    _8: u24 = 0,
};

/// Data word to be written to the I2C controller.
const DataIn = packed struct(u32) { value: u32 };

/// Transfer byte count.
const CntReg = packed struct(u32) {
    /// Number of bytes to transfer.
    len: u6,
    /// Not used.
    _6: u26 = 0,
};

/// Control register.
const CtlReg = packed struct(u32) {
    /// Data transfer format. 0: write, 1: read.
    dtf: enum(u2) {
        write = 0,
        read = 1,
    },
    /// Not used.
    _2: u2 = 0,
    /// SCL frequency select.
    scl_sel: u2,
    /// Enable interrupt.
    int_en: bool,
    /// Divide the clock.
    div_clk: bool,
    /// Not used.
    _8: u24 = 0,
};

/// Enable and interrupt.
const IicEnable = packed struct(u32) {
    /// Start the transfer.
    enable: bool,
    /// Transfer is completed.
    intrp: bool,
    /// Target returned NACK.
    noack: bool,
    /// Not used.
    _3: u1 = 0,
    /// Do not generate STOP condition.
    nostop: bool,
    /// Do not generate START condition.
    nostart: bool,
    ///
    restart: bool,
    /// Not used.
    _7: u25 = 0,
};

/// Data word read from the I2C controller.
const DataOut = packed struct(u32) { value: u32 };

/// Control register.
const CtlHi = packed struct(u32) {
    /// Disable waiting.
    wait_dis: bool,
    /// Ignore ACK.
    ignore_ack: bool,
    /// Not used.
    _2: u4 = 0,
    /// Data registers are 4 bytes wide.
    datareg_size: bool,
    /// Input switching level.
    input_switching_level: bool,
    /// Not used.
    _8: u24 = 0,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const mmio = common.mmio;
const rtt = common.rtt;
const arch = @import("arch").impl;
const dd = @import("dd");
const i2c = dd.i2c;
