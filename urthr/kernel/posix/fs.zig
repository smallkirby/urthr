//! POSIX compatibility layer for filesystem API.

/// System call: openat
pub fn sysOpenAt(dirfd: usize, pathname: [*:0]const u8, flags: i32, mode: u32) ReturnType {
    _ = mode;
    _ = flags;

    const allocator = urd.mem.getGeneralAllocator();
    const s = std.mem.span(pathname);

    // Check if pathname is relative or absolute.
    if (std.fs.path.isAbsolute(s)) {
        // Absolute path. Ignore directory.
        const file = urd.fs.open(s, allocator) catch |err| switch (err) {
            error.InvalidArgument => return .err(.inval),
            else => return .err(.again),
        };
        const fd = sched.getCurrent().fs.fdtbl.alloc(file) catch {
            return .err(.mfile);
        };
        return .success(@bitCast(fd));
    } else {
        // Relative path.
        const cur = sched.getCurrent();
        const dir = cur.fs.fdtbl.get(dirfd) catch {
            return .err(.badf);
        } orelse {
            return .err(.badf);
        };

        const file = urd.fs.openAt(dir, s, allocator) catch |err| switch (err) {
            error.InvalidArgument => return .err(.inval),
            else => return .err(.again),
        };
        const fd = cur.fs.fdtbl.alloc(file) catch {
            return .err(.mfile);
        };
        return .success(@bitCast(fd));
    }
}

/// System call: write
pub fn sysWrite(fd: usize, buf: usize, count: usize) ReturnType {
    const cur = sched.getCurrent();
    const file = cur.fs.fdtbl.get(fd) catch {
        return .err(.badf);
    } orelse {
        return .err(.badf);
    };

    const out = @as([*]const u8, @ptrFromInt(buf));

    const n = file.write(out[0..count]) catch |err| return switch (err) {
        else => .err(.again),
    };
    return .success(@bitCast(n));
}

const Iovec = extern struct {
    /// Starting address.
    base: [*]const u8,
    /// Number of bytes to transfer.
    len: usize,

    pub fn slice(self: Iovec) []const u8 {
        return self.base[0..self.len];
    }
};

/// System call: writev
pub fn sysWritev(fd: usize, iov: usize, iovcnt: usize) ReturnType {
    const cur = sched.getCurrent();
    const iovs = @as([*]const Iovec, @ptrFromInt(iov))[0..iovcnt];

    const file = cur.fs.fdtbl.get(fd) catch {
        return .err(.badf);
    } orelse {
        return .err(.badf);
    };

    var total: usize = 0;
    for (iovs) |v| {
        total += file.write(v.slice()) catch |err| return switch (err) {
            else => .err(.again),
        };
    }

    return .success(@bitCast(total));
}

/// System call: ioctl
pub fn sysIoctl(fd: usize, request: IoctlRequest, arg: usize) ReturnType {
    _ = fd;
    _ = arg;

    switch (request) {
        // TIOCGWINSZ
        .tiocgwinsz => {
            return .err(.notty);
        },

        // Unrecognized requests.
        _ => return .err(.inval),
    }
}

const IoctlRequest = enum(u64) {
    /// Get window size.
    tiocgwinsz = 0x5413,

    _,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const urd = @import("urthr");
const sched = urd.sched;
const ReturnType = urd.syscall.ReturnType;
