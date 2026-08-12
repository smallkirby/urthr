test "never fails" {
    var rgid: linux.gid_t = undefined;
    var egid: linux.gid_t = undefined;
    var sgid: linux.gid_t = undefined;

    const rc = linux.getresgid(&rgid, &egid, &sgid);
    try std.testing.expectEqual(@as(usize, 0), rc);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const linux = std.os.linux;
