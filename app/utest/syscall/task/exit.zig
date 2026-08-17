test "syscall: exit" {
    const expected_exit = 45;
    const ret = linux.fork();
    if (ret == 0) {
        _ = linux.syscall1(.exit, expected_exit);
        unreachable;
    }

    const child_pid: linux.pid_t = @intCast(ret);
    try testing.expect(child_pid > 0);

    var status: u32 = undefined;
    const wret = linux.wait4(child_pid, &status, 0, null);
    try testing.expectEqual(@as(usize, @intCast(child_pid)), wret);
    try testing.expectEqual(@as(u32, expected_exit << 8), status);
}

test "syscall: exit truncates the code to 8 bits" {
    const expected_exit: i32 = -1;
    const ret = linux.fork();
    if (ret == 0) {
        _ = linux.syscall1(.exit, @as(usize, @bitCast(@as(isize, expected_exit))));
        unreachable;
    }

    const child_pid: linux.pid_t = @intCast(ret);
    try testing.expect(child_pid > 0);

    var status: u32 = undefined;
    const wret = linux.wait4(child_pid, &status, 0, null);
    try testing.expectEqual(@as(usize, @intCast(child_pid)), wret);
    try testing.expectEqual(@as(u32, 0xFF00), status);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
