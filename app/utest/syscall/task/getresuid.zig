test "never fails" {
    var ruid: linux.uid_t = undefined;
    var euid: linux.uid_t = undefined;
    var suid: linux.uid_t = undefined;

    const rc = linux.getresuid(&ruid, &euid, &suid);
    try std.testing.expectEqual(@as(usize, 0), rc);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const linux = std.os.linux;
