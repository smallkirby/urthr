test "syscall: socket" {
    const fd = linux.socket(
        linux.AF.INET,
        linux.SOCK.STREAM,
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    _ = linux.close(@intCast(fd));
}

test "with an unsupported domain fails with EINVAL" {
    const fd = linux.socket(
        linux.AF.INET6,
        linux.SOCK.STREAM,
        0,
    );
    try testing.expectEqual(.INVAL, linux.errno(fd));
}

test "with an unsupported type fails with EINVAL" {
    const fd = linux.socket(
        linux.AF.INET,
        linux.SOCK.RAW,
        0,
    );
    try testing.expectEqual(.INVAL, linux.errno(fd));
}

test "syscall: socket with SOCK_DGRAM" {
    const fd = linux.socket(
        linux.AF.INET,
        linux.SOCK.DGRAM,
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    _ = linux.close(@intCast(fd));
}

test "with SOCK_NONBLOCK sets O_NONBLOCK on the fd" {
    const fd = linux.socket(
        linux.AF.INET,
        linux.SOCK.STREAM | linux.SOCK.NONBLOCK,
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const flags = linux.fcntl(@intCast(fd), linux.F.GETFL, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(flags));

    const O_NONBLOCK = 0o0004000;
    try testing.expect(flags & O_NONBLOCK != 0);
}

test "with SOCK_CLOEXEC sets the close-on-exec flag" {
    const fd = linux.socket(
        linux.AF.INET,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const FD_CLOEXEC = 1;
    const flags = linux.fcntl(@intCast(fd), linux.F.GETFD, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(flags));
    try testing.expectEqual(FD_CLOEXEC, flags);
}

test "can repeatedly create and close sockets" {
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const fd = linux.socket(
            linux.AF.INET,
            linux.SOCK.STREAM,
            0,
        );
        try testing.expectEqual(.SUCCESS, linux.errno(fd));
        try testing.expectEqual(
            .SUCCESS,
            linux.errno(linux.close(@intCast(fd))),
        );
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
