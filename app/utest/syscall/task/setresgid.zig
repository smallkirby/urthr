test "setresgid sets real, effective, and saved GID" {
    const nochange = std.math.maxInt(u32);
    const ret = linux.syscall5(.clone, 0, 0, 0, 0, 0);
    if (ret == 0) {
        var code: u8 = 0;
        var rgid: linux.gid_t = undefined;
        var egid: linux.gid_t = undefined;
        var sgid: linux.gid_t = undefined;

        if (linux.setresgid(1000, 2000, 3000) != 0) code |= 1;
        _ = linux.getresgid(&rgid, &egid, &sgid);
        if (rgid != 1000 or egid != 2000 or sgid != 3000) code |= 2;

        if (linux.setresgid(0, nochange, nochange) != 0) code |= 4;
        _ = linux.getresgid(&rgid, &egid, &sgid);
        if (rgid != 0) code |= 8;

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
