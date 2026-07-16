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

test "fails with EINVAL for signal number 0" {
    const ret = signal.sigAction(
        0,
        null,
        null,
        signal.mask_size,
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "fails with EINVAL for an out-of-range signal number" {
    const ret = signal.sigAction(
        999,
        null,
        null,
        signal.mask_size,
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "fails with EINVAL for SIGKILL" {
    const ret = signal.sigAction(
        @intFromEnum(linux.SIG.KILL),
        null,
        null,
        signal.mask_size,
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "fails with EINVAL for SIGSTOP" {
    const ret = signal.sigAction(
        @intFromEnum(linux.SIG.STOP),
        null,
        null,
        signal.mask_size,
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "fails with EINVAL for a wrong sigsetsize" {
    const ret = signal.sigAction(
        @intFromEnum(linux.SIG.TERM),
        null,
        null,
        signal.mask_size + 1,
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "can query the current action without changing it" {
    var old: signal.SigAction = undefined;
    const ret = signal.sigAction(
        @intFromEnum(linux.SIG.USR1),
        null,
        &old,
        signal.mask_size,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log;
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
const signal = utest.signal;
