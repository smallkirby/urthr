/// syscall: futex
pub fn sysFutex(uaddr: *u32, op: FutexOp, val: i32, timeout: ?*const Timespec, _: ?*align(1) u32, _: i32) ReturnType {
    const current = urd.sched.getCurrent();

    if (!urd.uaccess.accessOk(@intFromPtr(uaddr), @sizeOf(u32))) {
        return .err(.fault);
    }

    switch (op) {
        .wait => {
            const utimeout = if (timeout) |t| blk: {
                const ts = uaccess.getUser(Timespec, t) catch return .err(.fault);
                const cur = urd.time.getCurrentTimestamp();
                break :blk cur + @as(u64, @intCast(ts.sec * std.time.ns_per_s + ts.nsec));
            } else null;

            const woken = sync.futex.wait(
                @intFromPtr(uaddr),
                @as(u32, @bitCast(val)),
                current.vmm,
                utimeout,
            ) catch |e| return switch (e) {
                error.InvalidAddress => .err(.inval),
                error.OutOfMemory => .err(.nomem),
                error.NotExpected => .err(.again),
            };
            if (!woken) return .err(.timedout);

            return .success(0);
        },

        .wake => {
            const woken = sync.futex.wake(
                @intFromPtr(uaddr),
                current.vmm,
                @as(u32, @bitCast(val)),
            ) catch |e| return switch (e) {
                error.InvalidAddress => .err(.inval),
                error.OutOfMemory => .err(.nomem),
                error.NotExpected => .err(.again),
            };

            return .success(@intCast(woken));
        },

        _ => return .err(.nosys),
    }
}

const FutexOp = enum(i32) {
    /// Atomically verifies that the futex address still caintains the value,
    /// and sleeps awaiting a wakeup event on this futex address.
    wait = 0,
    /// Wakes at most `val` processes waiting on the futex address.
    wake = 1,

    _,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const urd = @import("urthr");
const sync = urd.sync;
const uaccess = urd.uaccess;
const Timespec = urd.posix.Timespec;
const ReturnType = urd.syscall.ReturnType;
