test "succeeds for SIG_BLOCK with an empty set" {
    var set: u64 = 0;
    const ret = signal.sigProcMask(signal.SIG_BLOCK, &set, null, signal.mask_size);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

test "SIG_BLOCK adds the given signals to the current mask" {
    var set: u64 = signal.sigBit(.TERM);
    var old: u64 = 0;

    try testing.expectEqual(.SUCCESS, linux.errno(signal.sigProcMask(signal.SIG_BLOCK, &set, null, signal.mask_size)));
    try testing.expectEqual(.SUCCESS, linux.errno(signal.sigProcMask(signal.SIG_BLOCK, null, &old, signal.mask_size)));
    try testing.expectEqual(true, old & signal.sigBit(.TERM) != 0);
}

test "SIG_UNBLOCK removes the given signals from the current mask" {
    var set: u64 = signal.sigBit(.TERM);
    var old: u64 = 0;

    try testing.expectEqual(.SUCCESS, linux.errno(signal.sigProcMask(signal.SIG_BLOCK, &set, null, signal.mask_size)));
    try testing.expectEqual(.SUCCESS, linux.errno(signal.sigProcMask(signal.SIG_UNBLOCK, &set, null, signal.mask_size)));
    try testing.expectEqual(.SUCCESS, linux.errno(signal.sigProcMask(signal.SIG_BLOCK, null, &old, signal.mask_size)));
    try testing.expectEqual(false, old & signal.sigBit(.TERM) != 0);
}

test "SIG_SETMASK replaces the current mask" {
    var first: u64 = signal.sigBit(.TERM);
    var second: u64 = signal.sigBit(.USR1);
    var old: u64 = 0;

    try testing.expectEqual(.SUCCESS, linux.errno(signal.sigProcMask(signal.SIG_BLOCK, &first, null, signal.mask_size)));
    try testing.expectEqual(.SUCCESS, linux.errno(signal.sigProcMask(signal.SIG_SETMASK, &second, null, signal.mask_size)));
    try testing.expectEqual(.SUCCESS, linux.errno(signal.sigProcMask(signal.SIG_BLOCK, null, &old, signal.mask_size)));
    try testing.expectEqual(false, old & signal.sigBit(.TERM) != 0);
    try testing.expectEqual(true, old & signal.sigBit(.USR1) != 0);
}

test "querying with a null set returns the current mask without changing it" {
    var old: u64 = undefined;
    const ret = signal.sigProcMask(signal.SIG_SETMASK, null, &old, signal.mask_size);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

test "fails with EINVAL for an invalid how value" {
    var set: u64 = 0;
    const ret = signal.sigProcMask(999, &set, null, signal.mask_size);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "fails with EINVAL for a wrong sigsetsize" {
    var set: u64 = 0;
    const ret = signal.sigProcMask(signal.SIG_BLOCK, &set, null, signal.mask_size + 1);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "SIGKILL and SIGSTOP cannot be blocked" {
    var set: u64 = signal.sigBit(.KILL) | signal.sigBit(.STOP);
    var old: u64 = 0;

    try testing.expectEqual(.SUCCESS, linux.errno(signal.sigProcMask(signal.SIG_BLOCK, &set, null, signal.mask_size)));
    try testing.expectEqual(.SUCCESS, linux.errno(signal.sigProcMask(signal.SIG_BLOCK, null, &old, signal.mask_size)));
    try testing.expectEqual(false, old & signal.sigBit(.KILL) != 0);
    try testing.expectEqual(false, old & signal.sigBit(.STOP) != 0);
}

test "a blocked signal is not delivered until it is unblocked" {
    handler_called = false;

    const sa: linux.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(.USR1, &sa, null);

    // Block SIGUSR1, then send it to self. It must stay pending and undelivered.
    var set: u64 = signal.sigBit(.USR1);
    try testing.expectEqual(.SUCCESS, linux.errno(signal.sigProcMask(signal.SIG_BLOCK, &set, null, signal.mask_size)));
    _ = linux.kill(linux.getpid(), .USR1);
    try testing.expectEqual(false, handler_called);

    // Unblocking must deliver the pending signal.
    try testing.expectEqual(.SUCCESS, linux.errno(signal.sigProcMask(signal.SIG_UNBLOCK, &set, null, signal.mask_size)));
    try testing.expectEqual(true, handler_called);
}

/// Whether the signal handler in the test above was called.
var handler_called: bool = false;

fn onSignal(signo: linux.SIG) callconv(.c) void {
    log.info("Signal#{d} handler called", .{@intFromEnum(signo)});
    handler_called = true;
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
