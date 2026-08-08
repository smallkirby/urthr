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

test "send and recv a plain HTTP request" {
    try utest.skipIfNetUnsupported();

    const fd = try connectedSocket();
    defer _ = linux.close(fd);

    // Send a simple HTTP request.
    const req = std.fmt.comptimePrint(
        "GET / HTTP/1.0\r\nHost: {s}\r\nConnection: close\r\n\r\n",
        .{utest.net.gateway_addr_str},
    );
    const sent = linux.sendto(fd, req, req.len, 0, null, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(sent));
    try testing.expectEqual(req.len, sent);

    // Receive the response.
    var buf: [256]u8 = undefined;
    const got = linux.recvfrom(fd, &buf, buf.len, 0, null, null);
    try testing.expectEqual(.SUCCESS, linux.errno(got));
    try testing.expect(got > 0);
    try testing.expect(std.mem.startsWith(u8, buf[0..got], "HTTP/"));
}

test "recv on a non-blocking connection fails with EAGAIN before any data arrives" {
    try utest.skipIfNetUnsupported();

    const fd = try connectedSocket();
    defer _ = linux.close(fd);

    // Ensure that the socket is non-blocking.
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(flags));
    const O_NONBLOCK = 0o4000;
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.fcntl(fd, linux.F.SETFL, flags | O_NONBLOCK),
    ));

    // Try to receive data before any has arrived.
    var buf: [16]u8 = undefined;
    const got = linux.recvfrom(
        fd,
        &buf,
        buf.len,
        0,
        null,
        null,
    );
    try testing.expectEqual(.AGAIN, linux.errno(got));
}

test "ppoll reports POLLIN once the response arrives on a non-blocking socket" {
    try utest.skipIfNetUnsupported();

    const fd = try connectedSocket();
    defer _ = linux.close(fd);

    // Ensure that the socket is non-blocking.
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(flags));
    const O_NONBLOCK = 0o4000;
    try testing.expectEqual(
        .SUCCESS,
        linux.errno(linux.fcntl(fd, linux.F.SETFL, flags | O_NONBLOCK)),
    );

    // Ensure that poll reports no events before any data has arrived.
    {
        var fds = [_]linux.pollfd{.{
            .fd = fd,
            .events = linux.POLL.IN,
            .revents = 0,
        }};
        var timeout: linux.timespec = .{ .sec = 1, .nsec = 0 };
        const ret = linux.ppoll(&fds, fds.len, &timeout, null);
        try testing.expectEqual(.SUCCESS, linux.errno(ret));
        try testing.expectEqual(@as(usize, 0), ret);
    }

    // Send a simple HTTP request.
    const req = std.fmt.comptimePrint(
        "GET / HTTP/1.0\r\nHost: {s}\r\nConnection: close\r\n\r\n",
        .{utest.net.gateway_addr_str},
    );
    const sent = linux.sendto(fd, req, req.len, 0, null, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(sent));

    // Wait for the response to arrive.
    {
        var fds = [_]linux.pollfd{.{
            .fd = fd,
            .events = linux.POLL.IN,
            .revents = 0,
        }};
        var timeout: linux.timespec = .{ .sec = 2, .nsec = 0 };
        const ret = linux.ppoll(&fds, fds.len, &timeout, null);
        try testing.expectEqual(.SUCCESS, linux.errno(ret));
        try testing.expectEqual(@as(usize, 1), ret);
        try testing.expect(fds[0].revents & linux.POLL.IN != 0);
    }

    // Returns no data once the connection has been closed by the peer.
    var buf: [16]u8 = undefined;
    const got = linux.recvfrom(fd, &buf, buf.len, 0, null, null);
    try testing.expectEqual(.SUCCESS, linux.errno(got));
}

test "send and recv on an unconnected socket fails" {
    const fd = linux.socket(
        linux.AF.INET,
        linux.SOCK.STREAM,
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const req = "x";
    const sent = linux.sendto(@intCast(fd), req, req.len, 0, null, 0);
    try testing.expect(linux.errno(sent) != .SUCCESS);

    var buf: [1]u8 = undefined;
    const got = linux.recvfrom(@intCast(fd), &buf, buf.len, 0, null, null);
    try testing.expect(linux.errno(got) != .SUCCESS);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
