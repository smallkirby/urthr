test "setgid changes GID and EGID when called by root" {
    const ret = linux.syscall5(.clone, 0, 0, 0, 0, 0);
    if (ret == 0) {
        var code: u8 = 0;
        if (linux.getgid() != 0) code |= 1;
        if (linux.setgid(1000) != 0) code |= 2;
        if (linux.getgid() != 1000 or linux.getegid() != 1000) code |= 4;
        if (linux.setgid(0) != 0) code |= 8;
        linux.exit_group(code);
    }

    const child_pid: linux.pid_t = @intCast(ret);
    try testing.expect(child_pid > 0);

    var status: u32 = undefined;
    const wret = linux.wait4(child_pid, &status, 0, null);
    try testing.expectEqual(@as(usize, @intCast(child_pid)), wret);
    try testing.expectEqual(@as(u32, 0), status);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
