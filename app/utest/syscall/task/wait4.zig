test "fails with ECHILD when the caller has no children" {
    var status: u32 = undefined;
    const ret = linux.wait4(
        linux.getpid(),
        &status,
        0,
        null,
    );
    try testing.expectEqual(.CHILD, linux.errno(ret));
}

test "with WNOHANG fails with ECHILD when the caller has no children" {
    const WNOHANG: u32 = 1;
    var status: u32 = undefined;
    const ret = linux.wait4(
        linux.getpid(),
        &status,
        WNOHANG,
        null,
    );
    try testing.expectEqual(.CHILD, linux.errno(ret));
}

test "waiting on a non-leader thread's own tid fails with ECHILD" {
    var pipe_parent: [2]i32 = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&pipe_parent, .{})));
    defer _ = linux.close(pipe_parent[0]);
    defer _ = linux.close(pipe_parent[1]);

    var pipe_leader: [2]i32 = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&pipe_leader, .{})));
    defer _ = linux.close(pipe_leader[0]);
    defer _ = linux.close(pipe_leader[1]);

    var pipe_worker: [2]i32 = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&pipe_worker, .{})));
    defer _ = linux.close(pipe_worker[0]);
    defer _ = linux.close(pipe_worker[1]);

    const S = struct {
        fn worker(fds: usize) callconv(.c) u8 {
            // Write own TID to the pipe.
            const pfds: *[2]i32 = @ptrFromInt(fds);
            const tid: i32 = @intCast(linux.gettid());
            _ = linux.write(pfds[1], std.mem.asBytes(&tid), @sizeOf(i32));

            // Block until the parent tells the worker to exit.
            var buf: [1]u8 = undefined;
            _ = linux.read(pfds[0], &buf, 1);
            linux.exit(0);
            unreachable;
        }
    };

    var ret: usize = undefined;
    ret = linux.fork();
    if (ret == 0) {
        // Child process: thread leader
        var fds = [2]i32{ pipe_worker[0], pipe_parent[1] };

        // Spawn a new thread in the same group.
        _ = utest.task.spawnThread(S.worker, @intFromPtr(&fds)) catch linux.exit_group(3);

        // Block until the parent tells the leader to exit.
        var buf: [1]u8 = undefined;
        _ = linux.read(pipe_leader[0], &buf, 1);
        linux.exit(0);
        unreachable;
    }

    const child_pid: linux.pid_t = @intCast(ret);
    try testing.expect(child_pid > 0);

    // Check if the worker's TID is different from the leader's PID.
    var worker_tid: i32 = undefined;
    try testing.expectEqual(
        @as(usize, @sizeOf(i32)),
        linux.read(pipe_parent[0], std.mem.asBytes(&worker_tid), @sizeOf(i32)),
    );
    try testing.expect(worker_tid > 0);
    try testing.expect(worker_tid != child_pid);

    // Cannot wait on non-leader thread.
    var status: u32 = undefined;
    ret = linux.wait4(worker_tid, &status, 0, null);
    try testing.expectEqual(.CHILD, linux.errno(ret));

    // Wait on the leader's PID succeeds.
    const go = [_]u8{1};
    _ = linux.write(pipe_leader[1], &go, 1);
    _ = linux.write(pipe_worker[1], &go, 1);
    ret = linux.wait4(child_pid, &status, 0, null);
    try testing.expectEqual(@as(usize, @intCast(child_pid)), ret);
}

test "a child forked by one thread can be wait-ed by another thread in the same group" {
    const S = struct {
        var grandchild_pid = std.atomic.Value(i32).init(0);
        var waiter_ready = std.atomic.Value(u32).init(0);
        var wait_succeeded = std.atomic.Value(i32).init(-1);

        // Waits for the grandchild's PID to be published, then wait on it.
        fn waiter(_: usize) callconv(.c) u8 {
            // Wait for the grandchild's PID to be published.
            var spins: usize = 0;
            var gc_pid: i32 = 0;
            while (spins < 100_000) : (spins += 1) {
                gc_pid = grandchild_pid.load(.acquire);
                if (gc_pid != 0) break;
                _ = linux.sched_yield();
            }

            // Wait on the grandchild's PID.
            // The grandchild is not forked by this thread though belongs to the same process.
            waiter_ready.store(1, .release);
            var status: u32 = undefined;
            const ret = linux.wait4(gc_pid, &status, 0, null);
            wait_succeeded.store(if (ret == @as(usize, @intCast(gc_pid))) 1 else 0, .release);
            linux.exit(0);
        }
    };

    var to_parent: [2]i32 = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&to_parent, .{})));
    defer _ = linux.close(to_parent[0]);
    defer _ = linux.close(to_parent[1]);

    var gc_gate: [2]i32 = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&gc_gate, .{})));
    defer _ = linux.close(gc_gate[0]);
    defer _ = linux.close(gc_gate[1]);

    const ret = linux.fork();
    if (ret == 0) {
        // Spawn a thread that will wait on the grandchild's PID.
        _ = utest.task.spawnThread(S.waiter, 0) catch linux.exit_group(2);

        // Fork a grandchild that blocks until told to exit.
        const gcret = linux.fork();
        if (gcret == 0) {
            var gbuf: [1]u8 = undefined;
            _ = linux.read(gc_gate[0], &gbuf, 1);
            linux.exit(42);
        }
        S.grandchild_pid.store(@intCast(gcret), .release);

        // Wait for the waiter thread to be ready to wait on the grandchild.
        var spins: usize = 0;
        while (S.waiter_ready.load(.acquire) == 0) : (spins += 1) {
            if (spins > 100_000) break;
            _ = linux.sched_yield();
        }
        // Give the waiter thread some opportunity to actually enter the blocking state.
        for (0..100) |_| _ = linux.sched_yield();

        // Let the grandchild exit.
        const go = [_]u8{1};
        _ = linux.write(gc_gate[1], &go, 1);

        // Wait for the waiter thread to report the reap result.
        spins = 0;
        while (S.wait_succeeded.load(.acquire) == -1) : (spins += 1) {
            if (spins > 100_000) break;
            _ = linux.sched_yield();
        }

        // Check wait result and report it to the parent.
        const msg = [_]u8{if (S.wait_succeeded.load(.acquire) == 1) 1 else 0};
        _ = linux.write(to_parent[1], &msg, 1);
        linux.exit(0);
    }

    const child_pid: linux.pid_t = @intCast(ret);
    try testing.expect(child_pid > 0);

    // Wait for the child to report the wait result.
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
