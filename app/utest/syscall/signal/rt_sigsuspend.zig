test "fails with EINVAL for a wrong sigsetsize" {
    var set: u64 = 0;
    const ret = signal.sigSuspend(&set, signal.mask_size + 1);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "blocks until an signal from other process is delivered" {
    alrm_handler_called = false;
    parent_pid = linux.getpid();

    const sa: linux.Sigaction = .{
        .handler = .{ .handler = onAlrm },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(.ALRM, &sa, null);

    // Block SIGALRM.
    var blockset: u64 = signal.sigBit(.ALRM);
    try testing.expectEqual(.SUCCESS, linux.errno(signal.sigProcMask(
        signal.SIG_BLOCK,
        &blockset,
        null,
        signal.mask_size,
    )));
    defer _ = signal.sigProcMask(
        signal.SIG_UNBLOCK,
        &blockset,
        null,
        signal.mask_size,
    );

    // Spawn a child process that sends SIGALRM to the parent.
    const ret = linux.fork();
    if (ret == 0) {
        // Give the parent time to enter suspend.
        _ = linux.nanosleep(&.{
            .sec = 0,
            .nsec = 20 * std.time.ns_per_ms,
        }, null);

        _ = linux.kill(parent_pid, .ALRM);

        // Give the parent time to handle the signal.
        _ = linux.nanosleep(&.{
            .sec = 0,
            .nsec = 20 * std.time.ns_per_ms,
        }, null);
        linux.exit_group(0);
    }
    const child_pid: linux.pid_t = @intCast(ret);
    try testing.expect(child_pid > 0);

    // Wait for a signal to arrive with empty block mask.
    var suspend_set: u64 = 0;
    const sret = signal.sigSuspend(&suspend_set, signal.mask_size);
    try testing.expectEqual(.INTR, linux.errno(sret));
    try testing.expectEqual(true, alrm_handler_called);

    // Check if the signal mask is restored.
    var cur: u64 = undefined;
    _ = signal.sigProcMask(signal.SIG_SETMASK, null, &cur, signal.mask_size);
    try testing.expectEqual(true, cur & signal.sigBit(.ALRM) != 0);

    try utest.expectWaitChild(child_pid, 0);
}

test "waked up only by unblocked signal" {
    usr1_handler_called = false;
    alrm_handler_called = false;
    parent_pid = linux.getpid();

    const sa1: linux.Sigaction = .{
        .handler = .{ .handler = onUsr1 },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(.USR1, &sa1, null);
    const sa2: linux.Sigaction = .{
        .handler = .{ .handler = onAlrm },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(.ALRM, &sa2, null);

    // Block SIGUSR1 and SIGALRM.
    var blockset: u64 = signal.sigBit(.USR1) | signal.sigBit(.ALRM);
    try testing.expectEqual(.SUCCESS, linux.errno(signal.sigProcMask(
        signal.SIG_BLOCK,
        &blockset,
        null,
        signal.mask_size,
    )));
    defer _ = signal.sigProcMask(
        signal.SIG_UNBLOCK,
        &blockset,
        null,
        signal.mask_size,
    );

    // Signal SIGUSR1 first to myself.
    try testing.expectEqual(.SUCCESS, linux.errno(linux.kill(
        parent_pid,
        .USR1,
    )));

    // Spawn a child process that sends SIGALRM to the parent.
    const ret = linux.fork();
    if (ret == 0) {
        // Give the parent time to enter suspend.
        _ = linux.nanosleep(&.{
            .sec = 0,
            .nsec = 20 * std.time.ns_per_ms,
        }, null);

        _ = linux.kill(parent_pid, .ALRM);

        // Give the parent time to handle the signal.
        _ = linux.nanosleep(&.{
            .sec = 0,
            .nsec = 20 * std.time.ns_per_ms,
        }, null);
        linux.exit_group(0);
    }
    const child_pid: linux.pid_t = @intCast(ret);
    try testing.expect(child_pid > 0);

    // Wake up by SIGALRM, but not by SIGUSR1.
    var suspend_set: u64 = signal.sigBit(.USR1);
    const sret = signal.sigSuspend(&suspend_set, signal.mask_size);
    try testing.expectEqual(.INTR, linux.errno(sret));
    try testing.expectEqual(false, usr1_handler_called);
    try testing.expectEqual(true, alrm_handler_called);

    try utest.expectWaitChild(child_pid, 0);
}

var parent_pid: linux.pid_t = undefined;
/// Whether SIGUSR1 handler was called.
var usr1_handler_called: bool = false;
/// Whether SIGALRM handler was called.
var alrm_handler_called: bool = false;

fn onUsr1(_: linux.SIG) callconv(.c) void {
    usr1_handler_called = true;
}

fn onAlrm(_: linux.SIG) callconv(.c) void {
    alrm_handler_called = true;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
const signal = utest.signal;
