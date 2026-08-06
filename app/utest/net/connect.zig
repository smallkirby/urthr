/// IP address used to test network connectivity.
const test_addr = utest.net.gateway_addr;
/// Port used to test network connectivity.
const test_port: u16 = utest.net.gateway_port;

test "syscall: connect" {
    try utest.skipIfNetUnsupported();

    const fd = linux.socket(
        linux.AF.INET,
        linux.SOCK.STREAM,
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const addr: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, test_port),
        .addr = test_addr,
    };
    const ret = linux.connect(
        @intCast(fd),
        @ptrCast(&addr),
        @sizeOf(linux.sockaddr.in),
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

test "with a short addrlen fails with EINVAL" {
    const fd = linux.socket(
        linux.AF.INET,
        linux.SOCK.STREAM,
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const addr: linux.sockaddr.in = .{ .port = 0, .addr = 0 };
    const ret = linux.connect(@intCast(fd), @ptrCast(&addr), 4);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "on a non-socket fd fails with EINVAL" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const addr: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, test_port),
        .addr = test_addr,
    };
    const ret = linux.connect(
        @intCast(fd),
        @ptrCast(&addr),
        @sizeOf(linux.sockaddr.in),
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
