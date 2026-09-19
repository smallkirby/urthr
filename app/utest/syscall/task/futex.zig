const S = struct {
    var word = std.atomic.Value(u32).init(0);

    /// Wakes the waiter after giving it some time.
    fn wakerThread(_: usize) callconv(.c) u8 {
        for (0..1000) |_| _ = linux.sched_yield();

        word.store(1, .release);
        _ = linux.futex_3arg(&word.raw, .{
            .cmd = .WAKE,
            .private = false,
        }, 1);

        return 0;
    }
};

test "FUTEX_WAIT blocks until woken by FUTEX_WAKE" {
    try utest.runChild(struct {
        pub fn lambda() !void {
            S.word.store(0, .release);

            _ = try utest.task.spawnThread(S.wakerThread, 0);

            // Sleep on the futex until woken up by the waker thread.
            const ret = linux.futex_4arg(&S.word.raw, .{
                .cmd = .WAIT,
                .private = false,
            }, 0, null);
            try testing.expectEqual(.SUCCESS, linux.errno(ret));
            try testing.expectEqual(1, S.word.load(.acquire));
        }
    });
}

test "FUTEX_WAIT returns EAGAIN immediately if the value already differs" {
    var word = std.atomic.Value(u32).init(1);

    const ret = linux.futex_4arg(&word.raw, .{
        .cmd = .WAIT,
        .private = false,
    }, 0, null);
    try testing.expectEqual(.AGAIN, linux.errno(ret));
}

test "FUTEX_WAIT times out when nobody wakes it" {
    var word = std.atomic.Value(u32).init(0);
    const ts: linux.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };

    const ret = linux.futex_4arg(&word.raw, .{
        .cmd = .WAIT,
        .private = false,
    }, 0, &ts);
    try testing.expectEqual(.TIMEDOUT, linux.errno(ret));
}

test "FUTEX_WAKE on an address with no waiters wakes nobody" {
    var word = std.atomic.Value(u32).init(0);

    const ret = linux.futex_3arg(&word.raw, .{
        .cmd = .WAKE,
        .private = false,
    }, 1);
    try testing.expectEqual(@as(usize, 0), ret);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
