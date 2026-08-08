test "syscall: bind a UDP socket to the wildcard address and port" {
    const fd = linux.socket(
        linux.AF.INET,
        linux.SOCK.DGRAM,
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const addr: linux.sockaddr.in = .{ .port = 0, .addr = 0 };
    const ret = linux.bind(
        @intCast(fd),
        @ptrCast(&addr),
        @sizeOf(linux.sockaddr.in),
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

test "binding two sockets to the same explicit port fails with EADDRINUSE" {
    const addr: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, 40000),
        .addr = 0,
    };

    // Create and bind the first socket to a specific port.
    const fd1 = linux.socket(
        linux.AF.INET,
        linux.SOCK.DGRAM,
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd1));
    defer _ = linux.close(@intCast(fd1));

    const ret1 = linux.bind(
        @intCast(fd1),
        @ptrCast(&addr),
        @sizeOf(linux.sockaddr.in),
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret1));

    // Create and bind the second socket to the same port, which should fail.
    const fd2 = linux.socket(
        linux.AF.INET,
        linux.SOCK.DGRAM,
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd2));
    defer _ = linux.close(@intCast(fd2));

    const ret2 = linux.bind(
        @intCast(fd2),
        @ptrCast(&addr),
        @sizeOf(linux.sockaddr.in),
    );
    try testing.expectEqual(.ADDRINUSE, linux.errno(ret2));
}

test "with a short addrlen fails with EINVAL" {
    const fd = linux.socket(
        linux.AF.INET,
        linux.SOCK.DGRAM,
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const addr: linux.sockaddr.in = .{ .port = 0, .addr = 0 };
    const ret = linux.bind(@intCast(fd), @ptrCast(&addr), 4);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "on a non-socket fd fails with EINVAL" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const addr: linux.sockaddr.in = .{ .port = 0, .addr = 0 };
    const ret = linux.bind(
        @intCast(fd),
        @ptrCast(&addr),
        @sizeOf(linux.sockaddr.in),
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "explicitly binding before connect still allows a UDP socket to connect" {
    try utest.skipIfNetUnsupported();

    const fd = linux.socket(
        linux.AF.INET,
        linux.SOCK.DGRAM,
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const local: linux.sockaddr.in = .{ .port = 0, .addr = 0 };
    const bret = linux.bind(
        @intCast(fd),
        @ptrCast(&local),
        @sizeOf(linux.sockaddr.in),
    );
    try testing.expectEqual(.SUCCESS, linux.errno(bret));

    const remote: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, utest.net.dns_port),
        .addr = utest.net.dns_addr,
    };
    const cret = linux.connect(
        @intCast(fd),
        @ptrCast(&remote),
        @sizeOf(linux.sockaddr.in),
    );
    try testing.expectEqual(.SUCCESS, linux.errno(cret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
