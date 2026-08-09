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

    const stack_size = 64 * 1024;
    const stack = try std.posix.mmap(
        null,
        stack_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    const sp = @intFromPtr(stack.ptr) + stack.len;

    const flags: u32 = linux.CLONE.VM | linux.CLONE.THREAD | linux.CLONE.SIGHAND;
    const ret = linux.clone(
        S.threadMain,
        sp,
        flags,
        0,
        null,
        0,
        null,
    );

    const child_tid: linux.pid_t = @bitCast(@as(u32, @truncate(ret)));
    try testing.expect(child_tid > 0);
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
