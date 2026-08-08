/// IP address used to test network connectivity.
const test_addr = utest.net.gateway_addr;
/// Port used to test network connectivity.
const test_port: u16 = utest.net.gateway_port;

/// Create a TCP socket and connect it to the test address and port.
fn connectedSocket() !i32 {
    const fd = linux.socket(
        linux.AF.INET,
        linux.SOCK.STREAM,
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));

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

    return @intCast(fd);
}

test "setsockopt: TCP_NODELAY on a connected socket succeeds" {
    try utest.skipIfNetUnsupported();

    const fd = try connectedSocket();
    defer _ = linux.close(fd);

    const on: i32 = 1;
    const ret = linux.setsockopt(
        fd,
        linux.IPPROTO.TCP,
        linux.TCP.NODELAY,
        std.mem.asBytes(&on),
        @sizeOf(i32),
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

test "setsockopt: SO_KEEPALIVE on a connected socket succeeds" {
    try utest.skipIfNetUnsupported();

    const fd = try connectedSocket();
    defer _ = linux.close(fd);

    const val: i32 = 1;
    const ret = linux.setsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.KEEPALIVE,
        std.mem.asBytes(&val),
        @sizeOf(i32),
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

test "setsockopt: unknown option fails with ENOPROTOOPT" {
    try utest.skipIfNetUnsupported();

    const fd = try connectedSocket();
    defer _ = linux.close(fd);

    const val: i32 = 1;
    const ret = linux.setsockopt(
        fd,
        linux.SOL.SOCKET,
        0x7FFF,
        std.mem.asBytes(&val),
        @sizeOf(i32),
    );
    try testing.expectEqual(.NOPROTOOPT, linux.errno(ret));
}

test "setsockopt: on a non-socket fd fails with EINVAL" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const val: i32 = 1;
    const ret = linux.setsockopt(
        @intCast(fd),
        linux.IPPROTO.TCP,
        linux.TCP.NODELAY,
        std.mem.asBytes(&val),
        @sizeOf(i32),
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "getsockopt: SO_ERROR on a connected socket reports no pending error" {
    try utest.skipIfNetUnsupported();

    const fd = try connectedSocket();
    defer _ = linux.close(fd);

    var err: i32 = -1;
    var len: u32 = @sizeOf(i32);
    const ret = linux.getsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.ERROR,
        std.mem.asBytes(&err),
        &len,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(@as(u32, @sizeOf(i32)), len);
    try testing.expectEqual(@as(i32, 0), err);
}

test "getsockopt: unsupported option fails with ENOPROTOOPT" {
    try utest.skipIfNetUnsupported();

    const fd = try connectedSocket();
    defer _ = linux.close(fd);

    var val: i32 = -1;
    var len: u32 = @sizeOf(i32);
    const ret = linux.getsockopt(
        fd,
        linux.IPPROTO.TCP,
        linux.TCP.NODELAY,
        std.mem.asBytes(&val),
        &len,
    );
    try testing.expectEqual(.NOPROTOOPT, linux.errno(ret));
}

test "getsockopt: on a non-socket fd fails with EINVAL" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    var err: i32 = -1;
    var len: u32 = @sizeOf(i32);
    const ret = linux.getsockopt(
        @intCast(fd),
        linux.SOL.SOCKET,
        linux.SO.ERROR,
        std.mem.asBytes(&err),
        &len,
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
