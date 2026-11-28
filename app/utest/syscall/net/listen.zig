test "accept a connection and exchange data" {
    try utest.skipIfNetUnsupported();

    const server = try listenOn(41001, 0);
    defer _ = linux.close(server);
    const client = try connectTo(41001);
    defer _ = linux.close(client);
    const conn = try acceptOn(server);
    defer _ = linux.close(conn);

    const ping = "ping";
    try testing.expectEqual(
        ping.len,
        linux.sendto(client, ping, ping.len, 0, null, 0),
    );
    var buf: [16]u8 = undefined;
    const got = linux.recvfrom(conn, &buf, buf.len, 0, null, null);
    try testing.expectEqualStrings(ping, buf[0..got]);

    const pong = "pong";
    try testing.expectEqual(
        pong.len,
        linux.sendto(conn, pong, pong.len, 0, null, 0),
    );
    const got2 = linux.recvfrom(client, &buf, buf.len, 0, null, null);
    try testing.expectEqualStrings(pong, buf[0..got2]);
}

test "accept reports the peer address" {
    try utest.skipIfNetUnsupported();

    const server = try listenOn(41002, 0);
    defer _ = linux.close(server);
    const client = try connectTo(41002);
    defer _ = linux.close(client);

    var local: linux.sockaddr.in = undefined;
    var local_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.getsockname(client, @ptrCast(&local), &local_len),
    ));

    var peer: linux.sockaddr.in = undefined;
    var peer_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    const conn = linux.accept(server, @ptrCast(&peer), &peer_len);
    try testing.expectEqual(.SUCCESS, linux.errno(conn));
    defer _ = linux.close(@intCast(conn));

    try testing.expectEqual(@as(linux.socklen_t, @sizeOf(linux.sockaddr.in)), peer_len);
    try testing.expectEqual(@as(u16, linux.AF.INET), peer.family);
    try testing.expectEqual(loopback_addr, peer.addr);
    try testing.expectEqual(local.port, peer.port);
}

test "getsockname and getpeername report the connection endpoints" {
    try utest.skipIfNetUnsupported();

    const server = try listenOn(41003, 0);
    defer _ = linux.close(server);
    const client = try connectTo(41003);
    defer _ = linux.close(client);
    const conn = try acceptOn(server);
    defer _ = linux.close(conn);

    var addr: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.getpeername(client, @ptrCast(&addr), &len),
    ));
    try testing.expectEqual(std.mem.nativeToBig(u16, 41003), addr.port);
    try testing.expectEqual(loopback_addr, addr.addr);

    len = @sizeOf(linux.sockaddr.in);
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.getsockname(conn, @ptrCast(&addr), &len),
    ));
    try testing.expectEqual(std.mem.nativeToBig(u16, 41003), addr.port);
}

test "getpeername on an unconnected socket fails with ENOTCONN" {
    try utest.skipIfNetUnsupported();

    const fd = try newSocket(linux.SOCK.STREAM);
    defer _ = linux.close(fd);

    var addr: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    try testing.expectEqual(.NOTCONN, linux.errno(
        linux.getpeername(fd, @ptrCast(&addr), &len),
    ));
}

test "getsockname reports the ephemeral port assigned by listen" {
    try utest.skipIfNetUnsupported();

    const fd = try newSocket(linux.SOCK.STREAM);
    defer _ = linux.close(fd);
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.listen(fd, 1),
    ));

    var addr: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    try testing.expectEqual(.SUCCESS, linux.errno(
        linux.getsockname(fd, @ptrCast(&addr), &len),
    ));
    try testing.expect(addr.port != 0);
}

test "accept on a non-blocking listener fails with EAGAIN" {
    try utest.skipIfNetUnsupported();

    const server = try listenOn(41004, linux.SOCK.NONBLOCK);
    defer _ = linux.close(server);

    try testing.expectEqual(.AGAIN, linux.errno(
        linux.accept(server, null, null),
    ));
}

test "accept4 applies SOCK_NONBLOCK and SOCK_CLOEXEC to the new socket" {
    try utest.skipIfNetUnsupported();

    const server = try listenOn(41005, 0);
    defer _ = linux.close(server);
    const client = try connectTo(41005);
    defer _ = linux.close(client);

    const conn = linux.accept4(server, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
    try testing.expectEqual(.SUCCESS, linux.errno(conn));
    defer _ = linux.close(@intCast(conn));

    const O_NONBLOCK = 0o4000;
    const status = linux.fcntl(@intCast(conn), linux.F.GETFL, 0);
    try testing.expect(status & O_NONBLOCK != 0);
    const fdflags = linux.fcntl(@intCast(conn), linux.F.GETFD, 0);
    try testing.expect(fdflags & linux.FD_CLOEXEC != 0);
}

test "a listening socket is readable once a connection is pending" {
    try utest.skipIfNetUnsupported();

    const server = try listenOn(41006, 0);
    defer _ = linux.close(server);

    var fds = [_]linux.pollfd{.{ .fd = server, .events = linux.POLL.IN, .revents = 0 }};
    try testing.expectEqual(0, linux.poll(&fds, 1, 0));

    const client = try connectTo(41006);
    defer _ = linux.close(client);

    fds[0].revents = 0;
    try testing.expectEqual(1, linux.poll(&fds, 1, 1000));
    try testing.expect(fds[0].revents & linux.POLL.IN != 0);
}

test "recv returns zero after the peer closes the connection" {
    try utest.skipIfNetUnsupported();

    const server = try listenOn(41007, 0);
    defer _ = linux.close(server);
    const client = try connectTo(41007);
    const conn = try acceptOn(server);
    defer _ = linux.close(conn);

    _ = linux.close(client);

    var buf: [8]u8 = undefined;
    try testing.expectEqual(0, linux.recvfrom(conn, &buf, buf.len, 0, null, null));
}

test "closing connections releases their sockets" {
    try utest.skipIfNetUnsupported();

    const server = try listenOn(41008, 0);
    defer _ = linux.close(server);

    for (0..4) |_| {
        const client = try connectTo(41008);
        const conn = try acceptOn(server);
        _ = linux.close(conn);
        _ = linux.close(client);
    }
}

test "listen on a non-socket fd fails with ENOTSOCK" {
    var fds: [2]i32 = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&fds, .{})));
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    try testing.expectEqual(.NOTSOCK, linux.errno(linux.listen(fds[0], 1)));
}

test "accept on a non-socket fd fails with ENOTSOCK" {
    var fds: [2]i32 = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&fds, .{})));
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    try testing.expectEqual(.NOTSOCK, linux.errno(linux.accept(fds[0], null, null)));
}

test "getsockname on a non-socket fd fails with ENOTSOCK" {
    var fds: [2]i32 = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&fds, .{})));
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    // std's wrapper does not accept NULL, so invoke the syscall directly.
    const ret = linux.syscall3(.getsockname, @intCast(fds[0]), 0, 0);
    try testing.expectEqual(.NOTSOCK, linux.errno(ret));
}

test "accept4 with an unknown flag fails with EINVAL" {
    try utest.skipIfNetUnsupported();

    const server = try listenOn(41010, 0);
    defer _ = linux.close(server);

    try testing.expectEqual(.INVAL, linux.errno(
        linux.accept4(server, null, null, 0x1),
    ));
}

test "listen on a UDP socket fails with EOPNOTSUPP" {
    try utest.skipIfNetUnsupported();

    const fd = try newSocket(linux.SOCK.DGRAM);
    defer _ = linux.close(fd);

    try testing.expectEqual(.OPNOTSUPP, linux.errno(
        linux.listen(fd, 1),
    ));
}

// =============================================================
// Helpers
// =============================================================

/// Loopback address in network byte order.
const loopback_addr = std.mem.nativeToBig(u32, 0x7F000001);

/// Create a new socket of the specified kind.
fn newSocket(kind: u32) !i32 {
    const fd = linux.socket(linux.AF.INET, kind, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    return @intCast(fd);
}

/// Create a TCP socket listening on the loopback address.
fn listenOn(port: u16, kind: u32) !i32 {
    const fd = try newSocket(linux.SOCK.STREAM | kind);
    errdefer _ = linux.close(fd);

    const addr: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = loopback_addr,
    };
    try testing.expectEqual(.SUCCESS, linux.errno(linux.bind(
        fd,
        @ptrCast(&addr),
        @sizeOf(linux.sockaddr.in),
    )));
    try testing.expectEqual(.SUCCESS, linux.errno(linux.listen(
        fd,
        4,
    )));

    return fd;
}

/// Connect a new TCP socket to the loopback address.
fn connectTo(port: u16) !i32 {
    const fd = try newSocket(linux.SOCK.STREAM);
    errdefer _ = linux.close(fd);

    const addr: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = loopback_addr,
    };
    try testing.expectEqual(.SUCCESS, linux.errno(linux.connect(
        fd,
        @ptrCast(&addr),
        @sizeOf(linux.sockaddr.in),
    )));

    return fd;
}

/// Accept an incoming connection on the listening socket.
fn acceptOn(fd: i32) !i32 {
    const conn = linux.accept(fd, null, null);
    try testing.expectEqual(.SUCCESS, linux.errno(conn));
    return @intCast(conn);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
