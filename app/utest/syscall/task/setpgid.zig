test "fails with EINVAL for a negative pgid" {
    const ret = linux.syscall2(.setpgid, 0, @bitCast(@as(isize, -1)));
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "on a session leader fails with EPERM" {
    // Set myself to session leader.
    try testing.expectEqual(.SUCCESS, linux.errno(linux.setsid()));

    const ret = linux.setpgid(0, 0);
    try testing.expectEqual(.PERM, linux.errno(ret));
}

test "propagates to every thread in the same thread group" {
    const S = struct {
        var pgid_matches = std.atomic.Value(i32).init(-1);

        // Worker thread that spins until it observes the target PGID.
        fn worker(target: usize) callconv(.c) u8 {
            var spins: usize = 0;
            var observed: usize = undefined;
            while (spins < 100_000) : (spins += 1) {
                observed = linux.getpgid(0);
                if (observed == target) break else _ = linux.sched_yield();
            }
            pgid_matches.store(if (observed == target) 1 else 0, .release);
            linux.exit(0);
        }
    };

    var to_parent: [2]i32 = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&to_parent, .{})));
    defer _ = linux.close(to_parent[0]);
    defer _ = linux.close(to_parent[1]);

    const ret = linux.fork();
    if (ret == 0) {
        // Child process: group leader.
        const tgid = linux.getpid();

        // Spawn a worker thread in the same group.
        _ = utest.task.spawnThread(S.worker, @intCast(tgid)) catch linux.exit_group(2);

        // Become own process group leader.
        _ = linux.setpgid(0, 0);

        // Wait for the worker to observe the new PGID.
        var spins: usize = 0;
        while (S.pgid_matches.load(.acquire) == -1) : (spins += 1) {
            if (spins > 100_000) break else _ = linux.sched_yield();
        }

        const msg = [_]u8{if (S.pgid_matches.load(.acquire) == 1) 1 else 0};
        _ = linux.write(to_parent[1], &msg, 1);
        linux.exit(0);
    }

    const child_pid: linux.pid_t = @intCast(ret);
    try testing.expect(child_pid > 0);

    var buf: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), linux.read(to_parent[0], &buf, 1));
    try testing.expectEqual(@as(u8, 1), buf[0]);

    var status: u32 = undefined;
    _ = linux.wait4(child_pid, &status, 0, null);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
