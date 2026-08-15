const S = struct {
    var leader_exited = std.atomic.Value(u32).init(0);

    const blocking_exit_code = 111;

    // Spin until the condition is met.
    fn waitUntil(flag: *std.atomic.Value(u32)) void {
        var spins: usize = 0;
        while (flag.load(.acquire) == 0) : (spins += 1) {
            if (spins > 100_000) return;
            _ = linux.sched_yield();
        }
    }

    /// Waits until the leader signals it is exiting to exit last.
    fn workerExitsLast(status: usize) callconv(.c) u8 {
        waitUntil(&leader_exited);
        // Give the leader some opportunity to fully leave the group.
        for (0..100) |_| _ = linux.sched_yield();
        linux.exit(@intCast(status));
        unreachable;
    }

    /// Exits immediately, without waiting for anything.
    fn workerExitsImmediately(status: usize) callconv(.c) u8 {
        linux.exit(@intCast(status));
        unreachable;
    }

    /// Blocks on a pipe read before exiting.
    fn workerBlocksThenExits(fd: usize) callconv(.c) u8 {
        var buf: [1]u8 = undefined;
        _ = linux.read(@intCast(fd), &buf, 1);
        linux.exit(blocking_exit_code);
        unreachable;
    }
};

test "last thread (non-leader)'s exit status is reported" {
    S.leader_exited.store(0, .release);

    const non_leader_exit_code: usize = 77;
    var ret = linux.syscall5(.clone, 0, 0, 0, 0, 0);
    if (ret == 0) {
        // Child process: group leader
        _ = utest.task.spawnThread(S.workerExitsLast, non_leader_exit_code) catch linux.exit_group(2);

        // Exit as the leader first, while the worker thread is still alive.
        S.leader_exited.store(1, .release);
        linux.exit(1);
    }

    const child_pid: linux.pid_t = @intCast(ret);
    try testing.expect(child_pid > 0);

    var status: u32 = undefined;
    ret = linux.wait4(child_pid, &status, 0, null);
    try testing.expectEqual(@as(usize, @intCast(child_pid)), ret);
    try testing.expectEqual(@as(u32, non_leader_exit_code << 8), status);
}

test "last thread (leader)'s exit status is reported" {
    const leader_exit_code: usize = 88;
    var ret = linux.syscall5(.clone, 0, 0, 0, 0, 0);
    if (ret == 0) {
        // Child process: group leader
        _ = utest.task.spawnThread(S.workerExitsImmediately, 1) catch linux.exit_group(2);

        // Give the worker some opportunity to exit and leave the group.
        for (0..100) |_| _ = linux.sched_yield();

        linux.exit(leader_exit_code);
    }

    const child_pid: linux.pid_t = @intCast(ret);
    try testing.expect(child_pid > 0);

    var status: u32 = undefined;
    ret = linux.wait4(child_pid, &status, 0, null);
    try testing.expectEqual(@as(usize, @intCast(child_pid)), ret);
    try testing.expectEqual(@as(u32, leader_exit_code << 8), status);
}

test "thread group is not waitable until every member has exited" {
    var to_parent: [2]i32 = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&to_parent, .{})));
    defer _ = linux.close(to_parent[0]);
    defer _ = linux.close(to_parent[1]);

    var to_worker: [2]i32 = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&to_worker, .{})));
    defer _ = linux.close(to_worker[0]);
    defer _ = linux.close(to_worker[1]);

    var ret = linux.syscall5(.clone, 0, 0, 0, 0, 0);
    if (ret == 0) {
        // Child process: group leader
        _ = utest.task.spawnThread(S.workerBlocksThenExits, @intCast(to_worker[0])) catch linux.exit_group(2);

        // Tell the parent the leader is about to exit, then exit first.
        const byte = [_]u8{1};
        _ = linux.write(to_parent[1], &byte, 1);
        linux.exit(99);
    }

    const child_pid: linux.pid_t = @intCast(ret);
    try testing.expect(child_pid > 0);

    // Wait until the leader has exited.
    var buf: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), linux.read(to_parent[0], &buf, 1));

    // The group is not waitable yet since the worker thread is still alive.
    var status: u32 = undefined;
    const WNOHANG = 1;
    ret = linux.wait4(child_pid, &status, WNOHANG, null);
    try testing.expectEqual(@as(usize, 0), ret);

    // Let the worker exit.
    const go = [_]u8{1};
    _ = linux.write(to_worker[1], &go, 1);

    ret = linux.wait4(child_pid, &status, 0, null);
    try testing.expectEqual(@as(usize, @intCast(child_pid)), ret);
    try testing.expectEqual(@as(u32, S.blocking_exit_code << 8), status);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
