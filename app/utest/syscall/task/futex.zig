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

const MultiWait = struct {
    var word = std.atomic.Value(u32).init(0);
    var woken_count = std.atomic.Value(u32).init(0);

    /// Blocks on a futex word and increments the counter.
    fn waiterThread(_: usize) callconv(.c) u8 {
        const ret = linux.futex_4arg(&word.raw, .{
            .cmd = .WAIT,
            .private = false,
        }, 0, null);
        if (linux.errno(ret) == .SUCCESS) {
            _ = woken_count.fetchAdd(1, .acq_rel);
        }

        return 0;
    }

    /// Spawns two waiters.
    fn spawnTwoWaiters() !void {
        word.store(0, .release);
        woken_count.store(0, .release);

        _ = try utest.task.spawnThread(waiterThread, 0);
        _ = try utest.task.spawnThread(waiterThread, 0);

        for (0..1000) |_| _ = linux.sched_yield();
    }

    /// Spins until the counter reaches the target value.
    fn waitForWoken(target: u32) void {
        var spins: usize = 0;
        while (woken_count.load(.acquire) < target) : (spins += 1) {
            if (spins > 100_000) return;
            _ = linux.sched_yield();
        }
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

test "FUTEX_WAIT succeeds instead of time-out when woken before the deadline" {
    try utest.runChild(struct {
        pub fn lambda() !void {
            S.word.store(0, .release);

            _ = try utest.task.spawnThread(S.wakerThread, 0);

            const ts: linux.timespec = .{ .sec = 5, .nsec = 0 };
            const ret = linux.futex_4arg(&S.word.raw, .{
                .cmd = .WAIT,
                .private = false,
            }, 0, &ts);
            try testing.expectEqual(.SUCCESS, linux.errno(ret));
            try testing.expectEqual(1, S.word.load(.acquire));
        }
    });
}

test "FUTEX_WAKE with upper limit of threads" {
    try utest.runChild(struct {
        pub fn lambda() !void {
            try MultiWait.spawnTwoWaiters();

            const ret = linux.futex_3arg(&MultiWait.word.raw, .{
                .cmd = .WAKE,
                .private = false,
            }, 1);
            try testing.expectEqual(@as(usize, 1), ret);

            MultiWait.waitForWoken(1);
            try testing.expectEqual(1, MultiWait.woken_count.load(.acquire));
        }
    });
}

test "FUTEX_WAKE wakes every waiter with upper limit" {
    try utest.runChild(struct {
        pub fn lambda() !void {
            try MultiWait.spawnTwoWaiters();

            const ret = linux.futex_3arg(&MultiWait.word.raw, .{
                .cmd = .WAKE,
                .private = false,
            }, 2);
            try testing.expectEqual(@as(usize, 2), ret);

            MultiWait.waitForWoken(2);
            try testing.expectEqual(2, MultiWait.woken_count.load(.acquire));
        }
    });
}

const NeverWoken = struct {
    var word = std.atomic.Value(u32).init(0);

    /// Blocks forever.
    fn blockForever(_: usize) callconv(.c) u8 {
        _ = linux.futex_4arg(&word.raw, .{
            .cmd = .WAIT,
            .private = false,
        }, 0, null);

        word.store(0xDEAD, .release);
        return 0;
    }
};

test "Never woken thread" {
    try utest.runChild(struct {
        pub fn lambda() !void {
            NeverWoken.word.store(0, .release);
            _ = try utest.task.spawnThread(NeverWoken.blockForever, 0);

            for (0..1000) |_| _ = linux.sched_yield();

            try testing.expectEqual(0, NeverWoken.word.load(.acquire));
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
