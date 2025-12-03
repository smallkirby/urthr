//! srboot: Send a Urthr kernel over serial to boot.

pub fn main() !void {
    if (os.argv.len != 2 + 1) {
        log.err("Usage: {s} <urthr.elf> <serial device>", .{os.argv[0]});
        return error.InvalidArgs;
    }

    const binary_path = std.mem.span(os.argv[1]);
    const serial_path = std.mem.span(os.argv[2]);

    // Open Urthr kernel.
    var urthr = try fs.cwd().openFile(binary_path, .{});
    defer urthr.close();

    // Open serial device.
    var sr = try fs.openFileAbsolute(serial_path, .{
        .mode = .read_write,
    });
    defer sr.close();

    var srboot = SrBoot{
        .sr = &sr,
        .urthr = &urthr,
    };
    try srboot.boot();
}

const SrBoot = struct {
    const Self = @This();

    /// Input buffer.
    buffer: [4096]u8 = undefined,
    /// Length of data in the buffer.
    len: usize = 0,
    /// Current state.
    state: State = .sync,
    /// Serial device file.
    sr: *fs.File,
    /// Urthr kernel file with header.
    urthr: *fs.File,

    const State = enum {
        sync,
        header,
        binary,
        complete,
    };

    pub fn boot(self: *Self) !void {
        log.info("PHASE: sync", .{});
        try self.sync();

        log.info("PHASE: header", .{});
        try self.sendHeader();

        log.info("PHASE: binary", .{});
        try self.sendBinary();

        log.info("PHASE: complete", .{});
        try self.waitAck();

        log.info("DONE", .{});
    }

    fn sync(self: *Self) !void {
        try self.sr.writeAll("SYNC");
        try self.waitAck();
    }

    fn sendHeader(self: *Self) !void {
        var header: UrthrHeader = undefined;
        const n = try self.urthr.readAll(std.mem.asBytes(&header));

        if (n != @sizeOf(UrthrHeader)) {
            return error.InvalidHeader;
        }

        if (!header.valid()) {
            return error.InvalidHeader;
        }

        try self.sr.writeAll(std.mem.asBytes(&header));

        try self.waitAck();
    }

    fn sendBinary(self: *Self) !void {
        var rbuf: [4096]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var writer = self.sr.writer(&wbuf);
        var reader = self.urthr.reader(&rbuf);

        // Discard header part.
        try reader.seekTo(@sizeOf(UrthrHeader));

        // Send binary part.
        _ = try reader.interface.streamRemaining(&writer.interface);
        try writer.interface.flush();

        try self.waitAck();
    }

    fn getc(self: *Self) !void {
        var buf: [1]u8 = undefined;
        _ = try self.sr.readAll(&buf);

        self.buffer[self.len] = buf[0];
        self.len += 1;
    }

    fn data(self: Self) []const u8 {
        return self.buffer[0..self.len];
    }

    fn clear(self: *Self) void {
        self.len = 0;
    }

    fn waitAck(self: *Self) !void {
        self.clear();

        while (true) {
            try self.getc();

            if (std.mem.eql(u8, self.data(), "ACK")) {
                break;
            }
        }

        self.clear();
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.srboot);
const os = std.os;
const fs = std.fs;
const common = @import("common");
const UrthrHeader = @import("boot").UrthrHeader;
