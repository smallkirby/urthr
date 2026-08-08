/// IP address of the fake DNS server started by the test harness.
const test_addr = utest.net.dns_addr;
/// Port of the fake DNS server started by the test harness.
const test_port: u16 = utest.net.dns_port;

/// Build a minimal DNS query for an A record.
fn buildQuery(buf: []u8, id: u16, name: []const u8) []u8 {
    var w: usize = 0;

    // Header: ID, flags (RD=1), QDCOUNT=1, ANCOUNT/NSCOUNT/ARCOUNT=0.
    std.mem.writeInt(u16, buf[w..][0..2], id, .big);
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 0x0100, .big);
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 1, .big);
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 0, .big);
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 0, .big);
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 0, .big);
    w += 2;

    // Question: QNAME as length-prefixed labels, terminated by a zero-length label.
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |label| {
        buf[w] = @intCast(label.len);
        w += 1;
        @memcpy(buf[w..][0..label.len], label);
        w += label.len;
    }
    buf[w] = 0;
    w += 1;

    // QTYPE=A(1), QCLASS=IN(1).
    std.mem.writeInt(u16, buf[w..][0..2], 1, .big);
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 1, .big);
    w += 2;

    return buf[0..w];
}

test "resolve a hostname to an IPv4 address over a UDP socket" {
    try utest.skipIfNetUnsupported();

    const fd = linux.socket(
        linux.AF.INET,
        linux.SOCK.DGRAM,
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

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

    var qbuf: [64]u8 = undefined;
    const query = buildQuery(&qbuf, 0x1234, "smallkirby.com");
    const sent = linux.sendto(
        @intCast(fd),
        query.ptr,
        query.len,
        0,
        null,
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(sent));
    try testing.expectEqual(query.len, sent);

    var rbuf: [256]u8 = undefined;
    const got = linux.recvfrom(
        @intCast(fd),
        &rbuf,
        rbuf.len,
        0,
        null,
        null,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(got));

    const resp = rbuf[0..got];
    try testing.expect(resp.len > 12);
    try testing.expectEqual(
        @as(u16, 0x1234),
        std.mem.readInt(u16, resp[0..2], .big),
    );
    const ancount = std.mem.readInt(u16, resp[6..8], .big);
    try testing.expectEqual(@as(u16, 1), ancount);

    // The answer's RDATA is the last 4 bytes of the fixed-format response.
    try testing.expectEqualSlices(u8, &utest.net.dns_answer_ip, resp[resp.len - 4 ..]);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
