test "setreuid drops privilege and blocks escalation" {
    const nochange = std.math.maxInt(u32);
    const ret = linux.syscall5(.clone, 0, 0, 0, 0, 0);
    if (ret == 0) {
        var code: u8 = 0;
        var ruid: linux.uid_t = undefined;
        var euid: linux.uid_t = undefined;
        var suid: linux.uid_t = undefined;

        // Drop privilege.
        if (linux.setreuid(1000, 1000) != 0) code |= 1;
        _ = linux.getresuid(&ruid, &euid, &suid);
        if (ruid != 1000 or euid != 1000 or suid != 1000) code |= 2;

        // Can't change EUID to root.
        if (linux.setreuid(nochange, 0) == 0) code |= 4;

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
