test "wrong magic1 fails with EINVAL" {
    const ret = linux.syscall4(
        .reboot,
        0,
        @intFromEnum(linux.LINUX_REBOOT.MAGIC2.MAGIC2),
        @intFromEnum(linux.LINUX_REBOOT.CMD.POWER_OFF),
        0,
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "wrong magic2 fails with EINVAL" {
    const ret = linux.syscall4(
        .reboot,
        @intFromEnum(linux.LINUX_REBOOT.MAGIC1.MAGIC1),
        0,
        @intFromEnum(linux.LINUX_REBOOT.CMD.POWER_OFF),
        0,
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
