test "timerfd_create fails with EINVAL for an invalid clock id" {
    const ret = linux.timerfd_create(@fromBackingInt(@intCast(time.CLOCK_INVALID)), .{});
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "timerfd_create fails with EINVAL for an invalid flag" {
    const ret = linux.timerfd_create(.MONOTONIC, @bitCast(@as(u32, 1)));
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "timerfd_settime fails with EBADF for an invalid fd" {
    const spec = itimerspec(0, 0);
    const ret = linux.timerfd_settime(-1, .{}, &spec, null);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "timerfd_settime fails with EINVAL when tv_nsec is out of range" {
    const fd = try create(.{ .NONBLOCK = true });
    defer _ = linux.close(fd);

    var spec = itimerspec(0, 0);
    spec.it_value.nsec = std.time.ns_per_s;
    const ret = linux.timerfd_settime(fd, .{}, &spec, null);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "read fails with EINVAL for a buffer smaller than 8 bytes" {
    const fd = try create(.{ .NONBLOCK = true });
    defer _ = linux.close(fd);

    var buf: [4]u8 = undefined;
    const ret = linux.read(fd, &buf, buf.len);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "read fails with EAGAIN on a nonblocking disarmed timer" {
    const fd = try create(.{ .NONBLOCK = true });
    defer _ = linux.close(fd);

    var count: u64 = undefined;
    const ret = linux.read(fd, std.mem.asBytes(&count), @sizeOf(u64));
    try testing.expectEqual(.AGAIN, linux.errno(ret));
}

test "one-shot timer expires once" {
    const fd = try create(.{ .NONBLOCK = true });
    defer _ = linux.close(fd);

    const spec = itimerspec(10 * std.time.ns_per_ms, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.timerfd_settime(fd, .{}, &spec, null),
    ));

    var count: u64 = undefined;
    try testing.expectEqual(.AGAIN, linux.errno(
        linux.read(fd, std.mem.asBytes(&count), @sizeOf(u64)),
    ));

    sleepMs(50);
    try testing.expectEqual(
        @sizeOf(u64),
        linux.read(fd, std.mem.asBytes(&count), @sizeOf(u64)),
    );
    try testing.expectEqual(1, count);

    // Consumed and not re-armed.
    try testing.expectEqual(.AGAIN, linux.errno(
        linux.read(fd, std.mem.asBytes(&count), @sizeOf(u64)),
    ));
    var cur: linux.itimerspec = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.timerfd_gettime(fd, &cur),
    ));
    try testing.expectEqual(0, cur.it_value.sec);
    try testing.expectEqual(0, cur.it_value.nsec);
}

test "periodic timer accumulates expirations" {
    const fd = try create(.{ .NONBLOCK = true });
    defer _ = linux.close(fd);

    const spec = itimerspec(5 * std.time.ns_per_ms, 5 * std.time.ns_per_ms);
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.timerfd_settime(fd, .{}, &spec, null),
    ));
    sleepMs(50);

    var count: u64 = undefined;
    try testing.expectEqual(
        @sizeOf(u64),
        linux.read(fd, std.mem.asBytes(&count), @sizeOf(u64)),
    );
    try testing.expect(count >= 2);

    var cur: linux.itimerspec = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.timerfd_gettime(fd, &cur),
    ));
    try testing.expectEqual(5 * std.time.ns_per_ms, @as(u64, @intCast(cur.it_interval.nsec)));
}

test "blocking read waits for the expiration" {
    const fd = try create(.{});
    defer _ = linux.close(fd);

    const spec = itimerspec(20 * std.time.ns_per_ms, 0);
    const start = nowNs();
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.timerfd_settime(fd, .{}, &spec, null),
    ));

    var count: u64 = undefined;
    try testing.expectEqual(
        @sizeOf(u64),
        linux.read(fd, std.mem.asBytes(&count), @sizeOf(u64)),
    );
    try testing.expectEqual(1, count);
    try testing.expect(nowNs() - start >= 20 * std.time.ns_per_ms);
}

test "poll reports readability after the expiration" {
    const fd = try create(.{ .NONBLOCK = true });
    defer _ = linux.close(fd);

    const spec = itimerspec(10 * std.time.ns_per_ms, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.timerfd_settime(fd, .{}, &spec, null),
    ));

    var fds = [_]linux.pollfd{.{
        .fd = fd,
        .events = linux.POLL.IN,
        .revents = 0,
    }};
    try testing.expectEqual(0, linux.poll(&fds, 1, 0));

    try testing.expectEqual(1, linux.poll(&fds, 1, 1000));
    try testing.expect(fds[0].revents & linux.POLL.IN != 0);
}

test "timerfd_settime with a zero value disarms the timer and returns the old setting" {
    const fd = try create(.{ .NONBLOCK = true });
    defer _ = linux.close(fd);

    const spec = itimerspec(10 * std.time.ns_per_s, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.timerfd_settime(fd, .{}, &spec, null),
    ));

    const disarm = itimerspec(0, 0);
    var old: linux.itimerspec = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.timerfd_settime(fd, .{}, &disarm, &old),
    ));
    try testing.expect(old.it_value.sec > 0);

    var count: u64 = undefined;
    sleepMs(20);
    try testing.expectEqual(.AGAIN, linux.errno(
        linux.read(fd, std.mem.asBytes(&count), @sizeOf(u64)),
    ));
}

// =============================================================
// Helpers
// =============================================================

fn create(flags: linux.TFD) !i32 {
    const ret = linux.timerfd_create(.MONOTONIC, flags);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    return @intCast(ret);
}

fn itimerspec(value_ns: u64, interval_ns: u64) linux.itimerspec {
    return .{
        .it_interval = .{
            .sec = @intCast(interval_ns / std.time.ns_per_s),
            .nsec = @intCast(interval_ns % std.time.ns_per_s),
        },
        .it_value = .{
            .sec = @intCast(value_ns / std.time.ns_per_s),
            .nsec = @intCast(value_ns % std.time.ns_per_s),
        },
    };
}

fn sleepMs(ms: u64) void {
    const req: linux.timespec = .{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast(ms % std.time.ms_per_s * std.time.ns_per_ms),
    };
    _ = linux.nanosleep(&req, null);
}

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = time.clockGetTime(time.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
const time = utest.time;
