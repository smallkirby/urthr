//! srboot: Send a Urthr kernel over serial to boot.

var terminate_thread: std.atomic.Value(bool) = .init(false);

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);

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

    // Print UART log until Enter is pressed.
    log.info("Press <Enter> to start booting Urthr kernel.", .{});
    try waitEnterWhileUart(
        &sr,
        &stdin_reader.interface,
        &stdout_writer.interface,
    );

    // Send Urthr kernel over serial.
    var srboot = SrBoot{
        .sr = &sr,
        .urthr = &urthr,
    };
    try srboot.boot();

    // Print UART log until interrupted.
    log.info("Completed booting. Press <Enter> to exit.", .{});
    try waitEnterWhileUart(
        &sr,
        &stdin_reader.interface,
        &stdout_writer.interface,
    );
}

/// Wait <Enter> key press while printing UART output.
fn waitEnterWhileUart(sr: *fs.File, stdin: *std.Io.Reader, stdout: *std.Io.Writer) !void {
    terminate_thread.store(false, .release);
    var thread = try std.Thread.spawn(
        .{},
        printUartThread,
        .{ sr, stdout },
    );

    while (true) {
        if (try stdin.takeByte() == '\n') break;
    }

    terminate_thread.store(true, .release);
    thread.join();
}

/// Thread function to print UART output.
fn printUartThread(sr: *fs.File, stdout: *std.Io.Writer) void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    const wait_time_ns = 10 * std.time.ns_per_ms;
    var buf: [1]u8 = undefined;
    var continue_poll = true;

    var poller = std.Io.poll(
        gpa.allocator(),
        enum { uart },
        .{ .uart = sr.* },
    );
    defer poller.deinit();

    // Poll UART and print received data to stdout.
    while (continue_poll and !terminate_thread.load(.acquire)) {
        continue_poll = poller.pollTimeout(wait_time_ns) catch {
            @panic("Failed to poll stdin.");
        };
        var reader = poller.reader(.uart);

        // Read until no more data is available.
        while (true) {
            _ = reader.readSliceShort(&buf) catch break;
            stdout.writeByte(buf[0]) catch {
                @panic("Failed to write to stdout.");
            };
            stdout.flush() catch {};
        }
    }

    log.info("UART print thread exiting.", .{});
}

const SrBoot = struct {
    const Self = @This();

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

    fn waitAck(self: *Self) !void {
        try self.waitForString("ACK");
    }

    fn waitForString(self: *Self, s: []const u8) !void {
        var buf: [1]u8 = undefined;
        var match_idx: usize = 0;

        while (true) {
            _ = try self.sr.read(&buf);
            if (buf[0] == s[match_idx]) {
                match_idx += 1;
                if (match_idx == s.len) {
                    return;
                }
            } else {
                match_idx = 0;
            }
        }
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
