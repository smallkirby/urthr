//! POSIX compatibility layer for the socket API.

// =============================================================
// socket

/// syscall: socket
pub fn sysSocket(domain: AddressFamily, typ: SockType, protocol: i32) ReturnType {
    if (protocol != 0) {
        return .err(.inval);
    }

    // Dispatch to appropriate socket creator based on the domain.
    return switch (domain) {
        .inet => socketInet(typ),
        else => .err(.inval),
    };
}

/// Create an IPv4 socket and return its file descriptor.
fn socketInet(typ: SockType) ReturnType {
    const open: *const fn () urd.net.Error!usize = switch (typ.kind) {
        .stream => urd.net.tcp.open,
        .dgram => urd.net.udp.open,
        else => return .err(.inval),
    };
    const close: *const fn (usize) void = switch (typ.kind) {
        .stream => urd.net.tcp.close,
        .dgram => urd.net.udp.close,
        else => unreachable,
    };
    const backend = switch (typ.kind) {
        .stream => &urd.net.tcp.socket_backend,
        .dgram => &urd.net.udp.socket_backend,
        else => unreachable,
    };

    const desc = open() catch return .err(.nomem);
    errdefer close(desc);
    const file = urd.fs.createSocket(backend, desc) catch return .err(.nomem);
    defer file.unref();

    // Update file flags.
    if (typ.nonblock) {
        file.status_flags.nonblock = true;
    }

    // Assign the socket file to a file descriptor.
    const cur = sched.getCurrent();
    const fd = cur.fs.fdtbl.allocAt(
        0,
        file,
        .{ .cloexec = typ.cloexec },
    ) catch return .err(.mfile);

    return .success(@intCast(fd));
}

// =============================================================
// connect

/// syscall: connect
pub fn sysConnect(fd: usize, addr: *SockAddr, addrlen: u32) ReturnType {
    if (addrlen < @sizeOf(SockAddr)) {
        return .err(.inval);
    }
    const file = getFile(fd) catch {
        return .err(.badf);
    };

    (switch (addr.general.family) {
        .inet => SocketFs.connect(
            file,
            .from(&addr.ipv4.addr),
            urd.net.util.fromNetEndian(addr.ipv4.port),
        ),
        else => return .err(.inval),
    }) catch |err| return switch (err) {
        fs.Error.NotSocket => .err(.inval),
        fs.Error.ConnectionRefused => .err(.econnrefused),
        else => .err(.again),
    };

    return .success(0);
}

// =============================================================
// bind

/// syscall: bind
pub fn sysBind(fd: usize, addr: *SockAddr, addrlen: u32) ReturnType {
    if (addrlen < @sizeOf(SockAddr)) {
        return .err(.inval);
    }
    const file = getFile(fd) catch {
        return .err(.badf);
    };

    (switch (addr.general.family) {
        .inet => SocketFs.bind(
            file,
            .from(&addr.ipv4.addr),
            urd.net.util.fromNetEndian(addr.ipv4.port),
        ),
        else => return .err(.inval),
    }) catch |err| return switch (err) {
        fs.Error.NotSocket => .err(.inval),
        else => .err(.addrinuse),
    };

    return .success(0);
}

// =============================================================
// sendto

/// syscall: sendto
pub fn sysSendTo(fd: usize, buf: [*]const u8, len: usize, _: i32, _: usize, _: u32) ReturnType {
    const file = getFile(fd) catch return .err(.badf);
    const data = buf[0..len];

    const written = file.write(data) catch |e| return switch (e) {
        fs.Error.WouldBlock => .err(.again),
        fs.Error.BadAccess => .err(.badf),
        else => .err(.again),
    };
    return .success(@bitCast(written));
}

// =============================================================
// recvfrom

/// syscall: recvfrom
pub fn sysRecvFrom(sockfd: usize, buf: [*]u8, len: usize, _: i32, _: usize, _: usize) ReturnType {
    const file = getFile(sockfd) catch return .err(.badf);
    const out = buf[0..len];

    const read = file.read(out) catch |e| return switch (e) {
        fs.Error.WouldBlock => .err(.again),
        fs.Error.BadAccess => .err(.badf),
        else => .err(.again),
    };
    return .success(@bitCast(read.len));
}

// =============================================================
// shutdown

/// Specifies how a socket should be shut down.
const ShutdownHow = enum(i32) {
    /// Further receptions will be disallowed.
    receive = 0,
    /// Further transmissions will be disallowed.
    send = 1,
    /// Further receptions and transmissions will be disallowed.
    both = 2,
};

/// syscall: shutdown
pub fn sysShutdown(sockfd: usize, _: ShutdownHow) ReturnType {
    const file = getFile(sockfd) catch {
        return .err(.badf);
    };
    SocketFs.shutdown(file, .{}) catch {
        return .err(.inval);
    };

    return .success(0);
}

// =============================================================
// setsockopt / getsockopt

/// Option level.
const SockOptLevel = enum(i32) {
    /// Common socket options.
    socket = 1,
    /// Options for IPv4 and IPv6 TCP sockets.
    tcp = 6,

    _,
};

/// Option name for common socket options.
const SocketOptName = enum(i32) {
    /// Allow reuse of local addresses.
    reuseaddr = 2,
    /// Get the last socket error.
    socket_error = 4,
    /// Total per-socket buffer space reserved for sends.
    sndbuf = 7,
    /// Total per-socket buffer space reserved for receives.
    rcvbuf = 8,
    /// Enables keep-alive for a socket connection.
    keepalive = 9,

    _,
};

/// Option name for TCP socket options.
const TcpOptName = enum(i32) {
    /// Enables or disables the Nagle algorithm for TCP sockets.
    nodelay = 1,
    /// Gets or sets the number of seconds a TCP connection will remain idle before keep-alive probes are sent.
    keepidle = 4,
    /// Gets or sets the number of seconds the connection will wait for a keepalive response before sending another keepalive probe.
    keepintvl = 5,
    /// Gets or sets the number of TCP keep-alive probes that will be sent before the connection is terminated.
    keepcnt = 6,

    _,
};

/// syscall: setsockopt
pub fn sysSetSockOpt(fd: usize, level: SockOptLevel, optname: i32, _: ?*const anyopaque, _: u32) ReturnType {
    const file = getFile(fd) catch return .err(.badf);
    if (file.getType() != .socket) return .err(.inval);

    return switch (level) {
        .socket => switch (@as(SocketOptName, @enumFromInt(optname))) {
            .reuseaddr,
            .sndbuf,
            .rcvbuf,
            .keepalive,
            => .success(0),
            else => .err(.noprotoopt),
        },
        .tcp => switch (@as(TcpOptName, @enumFromInt(optname))) {
            .nodelay,
            .keepidle,
            .keepintvl,
            .keepcnt,
            => .success(0),
            else => .err(.noprotoopt),
        },
        else => .err(.noprotoopt),
    };
}

/// syscall: getsockopt
pub fn sysGetSockOpt(fd: usize, level: SockOptLevel, optname: i32, optval: ?*align(1) i32, optlen: ?*u32) ReturnType {
    const file = getFile(fd) catch return .err(.badf);
    if (file.getType() != .socket) return .err(.inval);

    switch (level) {
        .socket => switch (@as(SocketOptName, @enumFromInt(optname))) {
            .socket_error => {
                const val = optval orelse return .err(.inval);
                const len = optlen orelse return .err(.inval);
                if (len.* < @sizeOf(i32)) return .err(.inval);

                val.* = 0;
                len.* = @sizeOf(i32);
                return .success(0);
            },
            else => return .err(.noprotoopt),
        },
        else => return .err(.noprotoopt),
    }
}

// =============================================================
// POSIX compliant types
// =============================================================

/// Address family.
const AddressFamily = enum(u16) {
    /// IP protocol family.
    inet = 2,

    _,
};

/// Socket type.
///
/// Serves to identify communication semantics and behavior of the socket.
const SockType = packed struct(u32) {
    /// Socket kind.
    kind: Kind,
    /// Non-blocking mode.
    nonblock: bool = false,
    /// Reserved.
    _12: u7 = 0,
    /// Close-on-exec mode.
    cloexec: bool = false,
    /// Reserved.
    _20: u12 = 0,

    /// Sequenced byte stream.
    const Kind = enum(u11) {
        stream = 1,
        dgram = 2,

        _,
    };
};

/// Address data.
const SockAddr = extern union {
    /// Opaqueue address data.
    general: extern struct {
        /// Address family.
        family: AddressFamily,
    },

    /// IPv4 address data.
    ipv4: extern struct {
        /// Address family.
        family: AddressFamily = .inet,
        /// Port number in network byte order.
        port: u16,
        /// IPv4 address in network byte order.
        addr: [4]u8,
        /// Reserved.
        zero: [8]u8 = @splat(0),
    },
};

// =============================================================
// Internal
// =============================================================

/// Get a file from the given file descriptor.
fn getFile(fd: usize) error{BadFileDescriptor}!*fs.File {
    const cur = sched.getCurrent();
    const file = cur.fs.fdtbl.get(fd) catch return error.BadFileDescriptor;
    return file orelse error.BadFileDescriptor;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const urd = @import("urthr");
const fs = urd.fs;
const SocketFs = fs.SocketFs;
const sched = urd.sched;
const ReturnType = urd.syscall.ReturnType;
