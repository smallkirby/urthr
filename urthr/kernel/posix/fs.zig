//! POSIX compatibility layer for filesystem API.

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

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const urd = @import("urthr");
const sched = urd.sched;
const ReturnType = urd.syscall.ReturnType;
