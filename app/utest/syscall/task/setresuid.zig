test "setresuid sets real, effective, and saved UID" {
    const nochange = std.math.maxInt(u32);
    const ret = linux.fork();
    if (ret == 0) {
        var code: u8 = 0;
        var ruid: linux.uid_t = undefined;
        var euid: linux.uid_t = undefined;
        var suid: linux.uid_t = undefined;

        if (linux.setresuid(1000, 2000, 3000) != 0) code |= 1;
        _ = linux.getresuid(&ruid, &euid, &suid);
        if (ruid != 1000 or euid != 2000 or suid != 3000) code |= 2;

        // Unprivileged now.
        if (linux.setresuid(0, nochange, nochange) == 0) code |= 4;
        if (linux.setresuid(3000, nochange, nochange) != 0) code |= 8;
        _ = linux.getresuid(&ruid, &euid, &suid);
        if (ruid != 3000) code |= 16;

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
