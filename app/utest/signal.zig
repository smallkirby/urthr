test "simple" {
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

    try testing.expectEqual(true, signal_called);
}

/// Whether signal handler is called.
var signal_called: bool = false;

/// Signal handler.
fn onSignal(signo: linux.SIG) callconv(.c) void {
    log.info("Signal#{d} handler called", .{@intFromEnum(signo)});
    signal_called = true;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log;
const testing = std.testing;
const linux = std.os.linux;
