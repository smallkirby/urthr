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
    ret = linux.syscall5(.clone, 0, 0, 0, 0, 0);
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

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
