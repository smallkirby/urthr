const S = struct {
    var shared_pid = std.atomic.Value(i32).init(0);

    fn threadMain(_: usize) callconv(.c) u8 {
        shared_pid.store(@intCast(linux.getpid()), .release);
        linux.exit(0);
    }
};

test "syscall: clone with CLONE_THREAD shares the address space and tgid" {
    S.shared_pid.store(0, .release);

    const parent_pid = linux.getpid();
    const parent_tid = linux.gettid();

    const child_tid = try utest.task.spawnThread(S.threadMain, 0);
    try testing.expect(child_tid != parent_tid);

    // Wait for the new thread to run and publish its write.
    var spins: usize = 0;
    while (S.shared_pid.load(.acquire) == 0) : (spins += 1) {
        if (spins > 100_000) return error.TestUnexpectedResult;
        _ = linux.sched_yield();
    }

    // PID is shared between parent and child.
    try testing.expectEqual(@as(i32, @intCast(parent_pid)), S.shared_pid.load(.acquire));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
