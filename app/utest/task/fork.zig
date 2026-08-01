// =============================================================
// clone

test "syscall: clone behaves like fork when no flags are given" {
    const expected_exit = 42;
    const ret = linux.syscall5(.clone, 0, 0, 0, 0, 0);
    if (ret == 0) {
        // Child: exit immediately.
        linux.exit_group(expected_exit);
    }

    const child_pid: linux.pid_t = @intCast(ret);
    try testing.expect(child_pid > 0);

    var status: u32 = undefined;
    const wret = linux.wait4(child_pid, &status, 0, null);
    try testing.expectEqual(@as(usize, @intCast(child_pid)), wret);
    try testing.expectEqual(@as(u32, expected_exit << 8), status);
}

// =============================================================
// fork

test "syscall: fork" {
    if (comptime !builtin.cpu.arch.isX86()) return error.SkipZigTest;

    const expected_exit = 43;
    const ret = linux.syscall0(.fork);
    if (ret == 0) {
        // Child: exit immediately.
        linux.exit_group(expected_exit);
    }

    const child_pid: linux.pid_t = @intCast(ret);
    try testing.expect(child_pid > 0);

    var status: u32 = undefined;
    const wret = linux.wait4(child_pid, &status, 0, null);
    try testing.expectEqual(@as(usize, @intCast(child_pid)), wret);
    try testing.expectEqual(@as(u32, expected_exit << 8), status);
}

// =============================================================
// vfork

test "syscall: vfork" {
    if (comptime !builtin.cpu.arch.isX86()) return error.SkipZigTest;

    const expected_exit = 44;
    const ret = linux.syscall0(.vfork);
    if (ret == 0) {
        // Child: exit immediately.
        linux.exit_group(expected_exit);
    }

    const child_pid: linux.pid_t = @intCast(ret);
    try testing.expect(child_pid > 0);

    var status: u32 = undefined;
    const wret = linux.wait4(child_pid, &status, 0, null);
    try testing.expectEqual(@as(usize, @intCast(child_pid)), wret);
    try testing.expectEqual(@as(u32, expected_exit << 8), status);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const linux = std.os.linux;
