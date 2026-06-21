//! Experimental init executable.

pub fn main(init: std.process.Init) !void {
    log.info("Initial process started.", .{});
    log.info("----------------------------------", .{});

    // Show arguments.
    {
        const allocator = init.arena.allocator();
        const args = try init.minimal.args.toSlice(allocator);
        defer allocator.free(args);

        log.info("Arguments: {d}", .{args.len});
        for (args, 0..) |arg, i| {
            log.info("  ARG#{d}: {s}", .{ i, arg });
        }
    }

    // Show environment variables.
    {
        log.info("Environment Variables: {d}", .{init.environ_map.count()});
        var enviter = init.environ_map.iterator();
        while (enviter.next()) |entry| {
            log.info("  ENV: {s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    // Test /dev/zero
    log.info("Testing /dev/zero.", .{});
    {
        const dzero = try std.Io.Dir.openFileAbsolute(init.io, "/dev/zero", .{});
        defer dzero.close(init.io);

        var buf: [16]u8 = undefined;
        var reader = dzero.reader(init.io, &.{});
        try reader.interface.readSliceAll(&buf);

        var writer = dzero.writer(init.io, &.{});
        try writer.interface.writeAll(&buf);
    }

    // Test /dev/null
    log.info("Testing /dev/null.", .{});
    {
        const dnull = try std.Io.Dir.openFileAbsolute(init.io, "/dev/null", .{});
        defer dnull.close(init.io);

        var buf: [16]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        var reader = dnull.reader(init.io, &.{});
        if (try reader.interface.streamRemaining(&w) != 0) {
            return error.UnexpectedNullRead;
        }

        var writer = dnull.writer(init.io, &.{});
        try writer.interface.writeAll(&buf);
    }

    // Test signal delivery.
    log.info("Testing signal delivery.", .{});
    {
        // Register a handler for SIGTERM.
        const sa: linux.Sigaction = .{
            .handler = .{ .handler = onSignal },
            .mask = linux.sigemptyset(),
            .flags = 0,
        };
        _ = linux.sigaction(.TERM, &sa, null);

        // Send SIGTERM to self.
        const pid = linux.getpid();
        _ = linux.kill(pid, .TERM);

        if (!signal_called) {
            return error.SignalNotDelivered;
        }
    }

    log.info("Testing sleep.", .{});
    {
        for (0..3) |i| {
            try std.Io.sleep(init.io, .fromSeconds(1), .awake);
            log.info("  {d}/3", .{i + 1});
        }
    }
}

/// Whether signal handler is called.
var signal_called: bool = false;

/// Signal handler.
fn onSignal(signo: linux.SIG) callconv(.c) void {
    log.info("Signal#{d} handler called", .{@intFromEnum(signo)});
    signal_called = true;
}

// =============================================================
// Panic
// =============================================================

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @branchHint(.cold);

    log.err("PANIC: {s}", .{msg});

    var it = StackIterator.init(@frameAddress());
    var ix: usize = 0;
    while (it.next()) |frame| : (ix += 1) {
        log.err("  #{d:0>2}: 0x{X:0>16}", .{ ix, frame });
    }

    std.posix.system.exit_group(99);
}

const StackIterator = struct {
    const Self = @This();

    fp: usize,

    pub fn init(start_fp: usize) Self {
        return .{ .fp = start_fp };
    }

    pub fn next(self: *Self) ?usize {
        const fp_addr = self.fp + 0;
        const ra_addr = self.fp + @sizeOf(usize);

        if (!isFrameValid(fp_addr, ra_addr)) {
            return null;
        }

        const fp_ptr: *const usize = @ptrFromInt(fp_addr);
        const ret_ptr: *const usize = @ptrFromInt(ra_addr);

        const fp = fp_ptr.*;
        const ra = ret_ptr.*;

        self.fp = fp;
        return ra;
    }

    fn isFrameValid(fp: usize, ra: usize) bool {
        return fp != 0 and
            ra != 0 and
            std.mem.isAligned(fp, @sizeOf(usize)) and
            std.mem.isAligned(ra, @sizeOf(usize)) and
            true;
    }
};

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const std = @import("std");
const log = std.log.scoped(.init);
const linux = std.os.linux;
