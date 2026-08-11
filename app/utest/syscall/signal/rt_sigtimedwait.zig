test "consumes an already pending signal immediately" {
    // Block the signal.
    var set: u64 = signal.sigBit(.USR1);
    try testing.expectEqual(.SUCCESS, linux.errno(signal.sigProcMask(
        signal.SIG_BLOCK,
        &set,
        null,
        signal.mask_size,
    )));
    defer _ = signal.sigProcMask(
        signal.SIG_UNBLOCK,
        &set,
        null,
        signal.mask_size,
    );

    // Send the signal to myself.
    try testing.expectEqual(.SUCCESS, linux.errno(linux.kill(
        linux.getpid(),
        .USR1,
    )));

    // Retrieve the blocked signal with a zero timeout.
    var info: linux.siginfo_t = undefined;
    const timeout: linux.timespec = .{ .sec = 0, .nsec = 0 };
    const ret = signal.sigTimedWait(
        &set,
        &info,
        &timeout,
        signal.mask_size,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(@intFromEnum(linux.SIG.USR1), @as(u32, @intCast(ret)));
    try testing.expectEqual(linux.SIG.USR1, info.signo);
}

test "time out with EAGAIN when the signal never arrives" {
    var set: u64 = signal.sigBit(.USR1);
    const timeout: linux.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
    const ret = signal.sigTimedWait(
        &set,
        null,
        &timeout,
        signal.mask_size,
    );
    try testing.expectEqual(.AGAIN, linux.errno(ret));
}

test "fails with EINVAL for a wrong sigsetsize" {
    var set: u64 = signal.sigBit(.USR1);
    const timeout: linux.timespec = .{ .sec = 0, .nsec = 0 };
    const ret = signal.sigTimedWait(
        &set,
        null,
        &timeout,
        signal.mask_size + 1,
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "consumes the signal so a second wait times out" {
    // Block the signal.
    var set: u64 = signal.sigBit(.USR1);
    try testing.expectEqual(.SUCCESS, linux.errno(signal.sigProcMask(
        signal.SIG_BLOCK,
        &set,
        null,
        signal.mask_size,
    )));
    defer _ = signal.sigProcMask(
        signal.SIG_UNBLOCK,
        &set,
        null,
        signal.mask_size,
    );

    // Send the signal to myself.
    try testing.expectEqual(.SUCCESS, linux.errno(linux.kill(
        linux.getpid(),
        .USR1,
    )));

    // First wait should succeed immediately.
    const zero_timeout: linux.timespec = .{ .sec = 0, .nsec = 0 };
    const first = signal.sigTimedWait(
        &set,
        null,
        &zero_timeout,
        signal.mask_size,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(first));

    // Second wait should time out.
    const short_timeout: linux.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
    const second = signal.sigTimedWait(
        &set,
        null,
        &short_timeout,
        signal.mask_size,
    );
    try testing.expectEqual(.AGAIN, linux.errno(second));
}

test "timer can wake up a thread" {
    if (comptime !builtin.cpu.arch.isX86()) return error.SkipZigTest;

    // Block the signal.
    var set: u64 = signal.sigBit(.ALRM);
    try testing.expectEqual(.SUCCESS, linux.errno(signal.sigProcMask(
        signal.SIG_BLOCK,
        &set,
        null,
        signal.mask_size,
    )));
    defer _ = signal.sigProcMask(
        signal.SIG_UNBLOCK,
        &set,
        null,
        signal.mask_size,
    );

    // Set a timer to send the signal after 5ms.
    const armed: time.Itimerval = .{
        .it_interval = .{ .sec = 0, .usec = 0 },
        .it_value = .{ .sec = 0, .usec = 5_000 },
    };
    try testing.expectEqual(.SUCCESS, linux.errno(time.setitimer(
        .REAL,
        &armed,
        null,
    )));

    // Wait for the signal with a 200ms timeout.
    const timeout: linux.timespec = .{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
    const ret = signal.sigTimedWait(
        &set,
        null,
        &timeout,
        signal.mask_size,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(@intFromEnum(linux.SIG.ALRM), @as(u32, @intCast(ret)));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
const signal = utest.signal;
const time = utest.time;
