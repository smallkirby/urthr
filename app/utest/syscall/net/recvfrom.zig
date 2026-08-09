/// IP address of the fake DNS server started by the test harness.
const test_addr = utest.net.dns_addr;
/// Port of the fake DNS server started by the test harness.
const test_port: u16 = utest.net.dns_port;

/// A query shorter than the fixed DNS header,
/// so the fake server's echoed question section is empty and its response becomes fully predictable.
const query = [_]u8{ 0xAB, 0xCD };
/// Expected prefix of the fake DNS server's response.
const expected_resp_prefix = [_]u8{
    0xAB, 0xCD, // Transaction ID, echoed back
    0x81, 0x80, // Flags: standard response, no error, recursion available
    0x00, 0x01, // QDCOUNT = 1
    0x00, 0x01, // ANCOUNT = 1
    0x00, 0x00, // NSCOUNT = 0
    0x00, 0x00, // ARCOUNT = 0
};

test "sendto an explicit destination on an unconnected UDP socket" {
    try utest.skipIfNetUnsupported();

    // Open UDP socket.
    const fd = linux.socket(
        linux.AF.INET,
        linux.SOCK.DGRAM,
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    // Send a DNS query to the fake DNS server and receive a response.
    const dest: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, test_port),
        .addr = test_addr,
    };
    const sent = linux.sendto(
        @intCast(fd),
        &query,
        query.len,
        0,
        @ptrCast(&dest),
        @sizeOf(linux.sockaddr.in),
    );
    try testing.expectEqual(.SUCCESS, linux.errno(sent));
    try testing.expectEqual(query.len, sent);

    // Receive from the server.
    var rbuf: [256]u8 = undefined;
    var from: linux.sockaddr.in align(4) = undefined;
    var fromlen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    const got = linux.recvfrom(
        @intCast(fd),
        &rbuf,
        rbuf.len,
        0,
        @ptrCast(&from),
        &fromlen,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(got));

    // Check if the sender's address matches the destination we sent to.
    try testing.expectEqual(linux.AF.INET, from.family);
    try testing.expectEqual(test_port, std.mem.bigToNative(u16, from.port));
    try testing.expectEqual(test_addr, from.addr);

    // Check the content of the response against the hardcoded expected header.
    const resp = rbuf[0..got];
    try testing.expectEqualSlices(u8, &expected_resp_prefix, resp[0..expected_resp_prefix.len]);
    try testing.expectEqualSlices(u8, &utest.net.dns_answer_ip, resp[resp.len - 4 ..]);
}

test "recvmsg receives a datagram and fills in the sender's address" {
    try utest.skipIfNetUnsupported();

    // Open UDP socket.
    const fd = linux.socket(
        linux.AF.INET,
        linux.SOCK.DGRAM,
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    // Connect to the server.
    const addr: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, test_port),
        .addr = test_addr,
    };
    const cret = linux.connect(
        @intCast(fd),
        @ptrCast(&addr),
        @sizeOf(linux.sockaddr.in),
    );
    try testing.expectEqual(.SUCCESS, linux.errno(cret));

    // Send a datagram to the server.
    const sent = linux.sendto(
        @intCast(fd),
        &query,
        query.len,
        0,
        null,
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(sent));

    // Receive from the server.
    var rbuf: [256]u8 = undefined;
    var iov = [_]std.posix.iovec{.{ .base = &rbuf, .len = rbuf.len }};
    var from: linux.sockaddr.in align(4) = undefined;
    var msg: linux.msghdr = .{
        .name = @ptrCast(&from),
        .namelen = @sizeOf(linux.sockaddr.in),
        .iov = &iov,
        .iovlen = iov.len,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    const got = linux.recvmsg(@intCast(fd), &msg, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(got));

    try testing.expectEqual(@sizeOf(linux.sockaddr.in), msg.namelen);
    try testing.expectEqual(linux.AF.INET, from.family);
    try testing.expectEqual(test_port, std.mem.bigToNative(u16, from.port));
    try testing.expectEqual(test_addr, from.addr);

    // Check the content of the response against the hardcoded expected header.
    const resp = rbuf[0..got];
    try testing.expectEqualSlices(u8, &expected_resp_prefix, resp[0..expected_resp_prefix.len]);
    try testing.expectEqualSlices(u8, &utest.net.dns_answer_ip, resp[resp.len - 4 ..]);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
