test "setuid drops privilege and blocks escalation" {
    const ret = linux.fork();
    if (ret == 0) {
        var code: u8 = 0;

        // Drop privilege.
        if (linux.getuid() != 0) code |= 1;
        if (linux.setuid(1000) != 0) code |= 2;
        if (linux.getuid() != 1000 or linux.geteuid() != 1000) code |= 4;
        // Cant change EUID to root.
        if (linux.setuid(0) == 0) code |= 8;

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
