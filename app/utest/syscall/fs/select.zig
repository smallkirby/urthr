test "pselect6 on an empty pipe times out and clears the set" {
    const fds = try pipe();
    defer closePipe(fds);

    var rset = FdSet.with(fds[0]);
    var timeout: linux.timespec = .{ .sec = 0, .nsec = 0 };
    const ret = pselect6(fds[0] + 1, &rset, null, null, &timeout);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(0, ret);
    try testing.expect(!rset.isSet(fds[0]));
}

test "pselect6 reports a readable pipe" {
    const fds = try pipe();
    defer closePipe(fds);
    try testing.expectEqual(1, linux.write(fds[1], "x", 1));

    var rset = FdSet.with(fds[0]);
    var timeout: linux.timespec = .{ .sec = 0, .nsec = 0 };
    const ret = pselect6(fds[0] + 1, &rset, null, null, &timeout);
    try testing.expectEqual(1, ret);
    try testing.expect(rset.isSet(fds[0]));
}

test "pselect6 reports a writable pipe" {
    const fds = try pipe();
    defer closePipe(fds);

    var wset = FdSet.with(fds[1]);
    var timeout: linux.timespec = .{ .sec = 0, .nsec = 0 };
    const ret = pselect6(fds[1] + 1, null, &wset, null, &timeout);
    try testing.expectEqual(1, ret);
    try testing.expect(wset.isSet(fds[1]));
}

test "pselect6 counts both readable and writable fds" {
    const fds = try pipe();
    defer closePipe(fds);
    try testing.expectEqual(1, linux.write(fds[1], "x", 1));

    var rset = FdSet.with(fds[0]);
    var wset = FdSet.with(fds[1]);
    var timeout: linux.timespec = .{ .sec = 0, .nsec = 0 };
    const ret = pselect6(@max(fds[0], fds[1]) + 1, &rset, &wset, null, &timeout);
    try testing.expectEqual(2, ret);
}

test "pselect6 waits for the timeout" {
    const fds = try pipe();
    defer closePipe(fds);

    var rset = FdSet.with(fds[0]);
    var timeout: linux.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
    const start = nowNs();
    const ret = pselect6(fds[0] + 1, &rset, null, null, &timeout);
    try testing.expectEqual(0, ret);
    try testing.expect(nowNs() - start >= 20 * std.time.ns_per_ms);
}

test "pselect6 writes back zero when the timeout expires" {
    const fds = try pipe();
    defer closePipe(fds);

    var rset = FdSet.with(fds[0]);
    var timeout: linux.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
    try testing.expectEqual(0, pselect6(fds[0] + 1, &rset, null, null, &timeout));
    try testing.expectEqual(0, timeout.sec);
    try testing.expectEqual(0, timeout.nsec);
}

test "pselect6 writes back the remaining time" {
    const fds = try pipe();
    defer closePipe(fds);
    try testing.expectEqual(1, linux.write(fds[1], "x", 1));

    var rset = FdSet.with(fds[0]);
    var timeout: linux.timespec = .{ .sec = 5, .nsec = 0 };
    try testing.expectEqual(1, pselect6(fds[0] + 1, &rset, null, null, &timeout));

    const remaining = @as(u64, @intCast(timeout.sec)) * std.time.ns_per_s + @as(u64, @intCast(timeout.nsec));
    try testing.expect(0 < remaining and remaining <= 5 * std.time.ns_per_s);
}

test "pselect6 does not modify the timeout on failure" {
    var timeout: linux.timespec = .{ .sec = 5, .nsec = 0 };
    var rset = FdSet.with(999);
    const ret = pselect6(1000, &rset, null, null, &timeout);
    try testing.expectEqual(.BADF, linux.errno(ret));
    try testing.expectEqual(5, timeout.sec);
}

test "pselect6 blocks until a timerfd expires" {
    const tfd: i32 = @intCast(linux.timerfd_create(.MONOTONIC, .{}));
    defer _ = linux.close(tfd);
    const spec: linux.itimerspec = .{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms },
    };
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.timerfd_settime(tfd, .{}, &spec, null),
    ));

    var rset = FdSet.with(tfd);
    var timeout: linux.timespec = .{ .sec = 5, .nsec = 0 };
    const ret = pselect6(tfd + 1, &rset, null, null, &timeout);
    try testing.expectEqual(1, ret);
    try testing.expect(rset.isSet(tfd));
}

test "pselect6 blocks without a timeout until the fd becomes ready" {
    const tfd: i32 = @intCast(linux.timerfd_create(.MONOTONIC, .{}));
    defer _ = linux.close(tfd);
    const spec: linux.itimerspec = .{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms },
    };
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.timerfd_settime(tfd, .{}, &spec, null),
    ));

    var rset = FdSet.with(tfd);
    try testing.expectEqual(1, pselect6(tfd + 1, &rset, null, null, null));
}

test "pselect6 fails with EBADF for an unopened fd" {
    var rset = FdSet.with(999);
    var timeout: linux.timespec = .{ .sec = 0, .nsec = 0 };
    const ret = pselect6(1000, &rset, null, null, &timeout);
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "pselect6 fails with EINVAL when nfds is too large" {
    var timeout: linux.timespec = .{ .sec = 0, .nsec = 0 };
    const ret = pselect6(1025, null, null, null, &timeout);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "pselect6 fails with EINVAL when tv_nsec is out of range" {
    var timeout: linux.timespec = .{ .sec = 0, .nsec = std.time.ns_per_s };
    const ret = pselect6(0, null, null, null, &timeout);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "select reports a readable pipe" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    const fds = try pipe();
    defer closePipe(fds);
    try testing.expectEqual(1, linux.write(fds[1], "x", 1));

    var rset = FdSet.with(fds[0]);
    var timeout: linux.timeval = .{ .sec = 0, .usec = 0 };
    const ret = linux.syscall5(
        .select,
        @intCast(fds[0] + 1),
        @intFromPtr(&rset),
        0,
        0,
        @intFromPtr(&timeout),
    );
    try testing.expectEqual(1, ret);
    try testing.expect(rset.isSet(fds[0]));
}

test "select fails with EINVAL when tv_usec is out of range" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    var timeout: linux.timeval = .{ .sec = 0, .usec = std.time.us_per_s };
    const ret = linux.syscall5(
        .select,
        0,
        0,
        0,
        0,
        @intFromPtr(&timeout),
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

// =============================================================
// Helpers
// =============================================================

const FdSet = extern struct {
    bits: [16]u64 = @splat(0),

    fn with(fd: i32) FdSet {
        var self: FdSet = .{};
        self.bits[@intCast(@divFloor(fd, 64))] |= @as(u64, 1) << @intCast(@mod(fd, 64));
        return self;
    }

    fn isSet(self: FdSet, fd: i32) bool {
        return self.bits[@intCast(@divFloor(fd, 64))] >> @intCast(@mod(fd, 64)) & 1 != 0;
    }
};

fn pselect6(nfds: i32, r: ?*FdSet, w: ?*FdSet, e: ?*FdSet, timeout: ?*linux.timespec) usize {
    return linux.syscall6(
        .pselect6,
        @intCast(nfds),
        @intFromPtr(r),
        @intFromPtr(w),
        @intFromPtr(e),
        @intFromPtr(timeout),
        0,
    );
}

fn pipe() ![2]i32 {
    var fds: [2]i32 = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.pipe2(&fds, .{}),
    ));
    return fds;
}

fn closePipe(fds: [2]i32) void {
    _ = linux.close(fds[0]);
    _ = linux.close(fds[1]);
}

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = utest.time.clockGetTime(utest.time.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
