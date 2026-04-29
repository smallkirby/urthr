//! srboot: Send a Urthr kernel over serial to boot.

var terminate_thread: std.atomic.Value(bool) = .init(false);

var opts: struct {
    // Abort when the first sync request does not succeed in 5 seconds.
    quick: bool = false,
    // Do not wait for user input to start booting.
    nowait: bool = false,
} = .{};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.gpa);
    defer gpa.free(args);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);

    if (args.len < 2 + 1) {
        log.err("Usage: {s} <urthr.elf> <serial device> <?options>", .{args[0]});
        return error.InvalidArgs;
    }

    const binary_path = args[1];
    const serial_path = args[2];

    // Open CWD.
    var cwd_buf: [128]u8 = undefined;
    const cwd_path = cwd_buf[0..try std.process.currentPath(init.io, &cwd_buf)];
    const cwd = try std.Io.Dir.openDirAbsolute(init.io, cwd_path, .{});
    defer cwd.close(io);

    // Parse options.
    for (0..args.len - 3) |i| {
        const option = args[3 + i];
        if (std.mem.eql(u8, option, "--quick")) {
            opts.quick = true;
        } else if (std.mem.eql(u8, option, "--nowait")) {
            opts.nowait = true;
        } else {
            log.err("Unknown option: {s}", .{option});
            return error.InvalidArgs;
        }
    }

    // Open Urthr kernel.
    var urthr = try cwd.openFile(io, binary_path, .{});
    defer urthr.close(io);

    // Open serial device.
    var sr = try std.Io.Dir.openFileAbsolute(io, serial_path, .{
        .mode = .read_write,
    });
    defer sr.close(io);

    // Configure baudrate.
    try setBaudrate(&sr, 921600);

    // Print UART log until Enter is pressed.
    if (!opts.nowait) {
        log.info("Press <Enter> to start booting Urthr kernel.", .{});
        try waitEnterWhileUart(
            &sr,
            &stdin_reader.interface,
            &stdout_writer.interface,
            io,
        );
    }

    // Send Urthr kernel over serial.
    var srboot = SrBoot{
        .sr = &sr,
        .urthr = &urthr,
        .io = io,
    };
    try srboot.boot();

    // Print UART log until interrupted.
    log.info("Completed booting. Press <Enter> to exit.", .{});
    try waitEnterWhileUart(
        &sr,
        &stdin_reader.interface,
        &stdout_writer.interface,
        io,
    );
}

/// Set the baudrate of the serial device.
fn setBaudrate(sr: *std.Io.File, comptime baudrate: u32) !void {
    const linux = std.os.linux;
    const speed: linux.speed_t = switch (baudrate) {
        19200 => .B19200,
        921600 => .B921600,
        else => @compileError("Unsupported baudrate"),
    };

    var termios: linux.termios = undefined;
    _ = linux.tcgetattr(sr.handle, &termios);
    termios.ispeed = speed;
    termios.ospeed = speed;
    _ = linux.tcsetattr(sr.handle, linux.TCSA.NOW, &termios);
}

/// Blocks until <Enter> key press while printing UART output.
fn waitEnterWhileUart(
    sr: *std.Io.File,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    io: std.Io,
) !void {
    var task = io.async(
        printUartThread,
        .{ sr, stdout, io },
    );

    while (true) {
        if (!opts.quick) {
            if (try stdin.takeByte() == '\n') break;
        }
    }

    _ = task.cancel(io);
}

const TimeoutKiller = struct {
    /// Timeout in nanoseconds.
    timeout: u64,
    /// Thread instance.
    _thread: std.Thread = undefined,
    /// Stop flag.
    _stop: std.atomic.Value(bool) = .init(false),
    /// I/O interface.
    io: std.Io,

    const f = struct {
        fn f(timeout_ns: ?u64, flag: *const std.atomic.Value(bool), io: std.Io) void {
            if (timeout_ns) |ns| {
                const s = std.Io.Timestamp.now(io, .real).nanoseconds;
                while (!flag.load(.acquire) and
                    (std.Io.Timestamp.now(io, .real).nanoseconds - s) < ns)
                {
                    std.atomic.spinLoopHint();
                }

                if (!flag.load(.acquire)) {
                    log.err("Operation timed out. Exiting.", .{});
                    std.process.exit(1);
                }
            } else {
                std.atomic.spinLoopHint();
            }
        }
    }.f;

    pub fn new(timeout: u64, io: std.Io) TimeoutKiller {
        return .{ .timeout = timeout, .io = io };
    }

    pub fn start(self: *TimeoutKiller) !void {
        self._thread = try std.Thread.spawn(
            .{},
            f,
            .{ self.timeout, &self._stop, self.io },
        );
    }

    pub fn stop(self: *TimeoutKiller) void {
        self._stop.store(true, .release);
        self._thread.join();
    }
};

/// Thread function to print UART output.
fn printUartThread(
    sr: *std.Io.File,
    stdout: *std.Io.Writer,
    io: std.Io,
) void {
    var buf: [1]u8 = undefined;
    var reader = sr.reader(io, &.{});

    // Poll UART and print received data to stdout.
    while (true) {
        _ = reader.interface.readSliceShort(&buf) catch |err| switch (err) {
            // Error happens when this thread is requested to be cancelled.
            else => break,
        };

        if (!std.ascii.isAscii(buf[0])) continue;

        stdout.writeByte(buf[0]) catch {
            @panic("Failed to write to stdout.");
        };
        stdout.flush() catch {};
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
    sr: *std.Io.File,
    /// Urthr kernel file with header.
    urthr: *std.Io.File,
    /// I/O interface.
    io: std.Io,

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
        try self.sr.writeStreamingAll(self.io, "SYNC");

        if (opts.quick) {
            var killer = TimeoutKiller.new(
                5 * std.time.ns_per_s,
                self.io,
            );
            try killer.start();
            defer killer.stop();

            try self.waitAck();
        } else {
            try self.waitAck();
        }
    }

    fn sendHeader(self: *Self) !void {
        var header: UrthrHeader = undefined;
        var reader = self.urthr.reader(self.io, &.{});
        try reader.interface.readSliceAll(std.mem.asBytes(&header));

        if (!header.valid()) {
            return error.InvalidHeader;
        }

        var writer = self.sr.writer(self.io, &.{});
        try writer.interface.writeStruct(header, .little);

        try self.waitAck();
    }

    fn sendBinary(self: *Self) !void {
        var rbuf: [4096]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var writer = self.sr.writer(self.io, &wbuf);
        var reader = self.urthr.reader(self.io, &rbuf);

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

        var reader = self.sr.readerStreaming(self.io, &.{});
        while (true) {
            _ = try reader.interface.readSliceShort(&buf);
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
const Allocator = std.mem.Allocator;
const os = std.os;
const fs = std.fs;
const common = @import("common");
const UrthrHeader = @import("boot").UrthrHeader;
