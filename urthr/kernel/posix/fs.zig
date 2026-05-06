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

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const urd = @import("urthr");
const sched = urd.sched;
const ReturnType = urd.syscall.ReturnType;
