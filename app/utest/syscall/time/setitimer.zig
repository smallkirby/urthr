test "delivers SIGALRM once after ITIMER_REAL expires" {
    if (comptime !builtin.cpu.arch.isX86()) return error.SkipZigTest;

    installAlarmHandler();
    defer restoreAlarmHandler();
    defer disarm();

    alarm_count = 0;

    const new_value: time.Itimerval = .{
        .it_interval = .{ .sec = 0, .usec = 0 },
        .it_value = .{ .sec = 0, .usec = 5_000 },
    };
    const ret = time.setitimer(.REAL, &new_value, null);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    try sleepMs(50);

    try testing.expectEqual(1, alarm_count);
}

test "repeats at it_interval when set" {
    if (comptime !builtin.cpu.arch.isX86()) return error.SkipZigTest;

    installAlarmHandler();
    defer restoreAlarmHandler();
    defer disarm();

    alarm_count = 0;

    const new_value: time.Itimerval = .{
        .it_interval = .{ .sec = 0, .usec = 5_000 },
        .it_value = .{ .sec = 0, .usec = 5_000 },
    };
    const ret = time.setitimer(.REAL, &new_value, null);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    for (0..10) |_| {
        try sleepMs(10);
    }

    try testing.expect(alarm_count >= 2);
}

test "a zero it_value disarms the timer" {
    if (comptime !builtin.cpu.arch.isX86()) return error.SkipZigTest;

    installAlarmHandler();
    defer restoreAlarmHandler();

    alarm_count = 0;

    // Set a timer that will fire after 5ms.
    const armed: time.Itimerval = .{
        .it_interval = .{ .sec = 0, .usec = 0 },
        .it_value = .{ .sec = 0, .usec = 5_000 },
    };
    var ret = time.setitimer(.REAL, &armed, null);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    // Disarm the timer.
    const disarmed: time.Itimerval = std.mem.zeroes(time.Itimerval);
    ret = time.setitimer(.REAL, &disarmed, null);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    // Reset the counter.
    alarm_count = 0;

    try sleepMs(50);

    try testing.expectEqual(0, alarm_count);
}

test "returns the previous setting in old_value" {
    if (comptime !builtin.cpu.arch.isX86()) return error.SkipZigTest;

    defer disarm();

    const first: time.Itimerval = .{
        .it_interval = .{ .sec = 0, .usec = 0 },
        .it_value = .{ .sec = 1, .usec = 0 },
    };
    var ret = time.setitimer(.REAL, &first, null);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    var old: time.Itimerval = undefined;
    const second: time.Itimerval = std.mem.zeroes(time.Itimerval);
    ret = time.setitimer(.REAL, &second, &old);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    // Remaining time should be close to but no greater than the 1 second armed above.
    try testing.expect(old.it_value.sec == 0 or old.it_value.sec == 1);
    try testing.expect(old.it_value.sec != 0 or old.it_value.usec > 0);
}

test "fails with ENOSYS for ITIMER_VIRTUAL and ITIMER_PROF" {
    if (comptime !builtin.cpu.arch.isX86()) return error.SkipZigTest;

    const value: time.Itimerval = .{
        .it_interval = .{ .sec = 0, .usec = 0 },
        .it_value = .{ .sec = 0, .usec = 0 },
    };

    const ret_virtual = time.setitimer(.VIRTUAL, &value, null);
    try testing.expectEqual(.NOSYS, linux.errno(ret_virtual));

    const ret_prof = time.setitimer(.PROF, &value, null);
    try testing.expectEqual(.NOSYS, linux.errno(ret_prof));
}

/// Number of times the SIGALRM handler has fired since it was last reset.
var alarm_count: u32 = 0;

/// Callback invoked when the SIGALRM signal is delivered to this process.
fn onAlarm(_: linux.SIG) callconv(.c) void {
    alarm_count += 1;
}

/// Install a SIGALRM handler that increments `alarm_count` each time it is invoked.
fn installAlarmHandler() void {
    const sa: linux.Sigaction = .{
        .handler = .{ .handler = onAlarm },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(.ALRM, &sa, null);
}

/// Restore the default SIGALRM handler.
fn restoreAlarmHandler() void {
    const sa: linux.Sigaction = .{
        .handler = .{ .handler = linux.SIG.DFL },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(.ALRM, &sa, null);
}

/// Disarm the ITIMER_REAL timer.
fn disarm() void {
    const zero: time.Itimerval = std.mem.zeroes(time.Itimerval);
    _ = time.setitimer(.REAL, &zero, null);
}

fn sleepMs(ms: u64) !void {
    const req: linux.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    const ret = time.clockNanoSleep(time.CLOCK_MONOTONIC, 0, &req, null);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
const time = utest.time;
