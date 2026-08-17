test "setregid sets GID and EGID" {
    const nochange = std.math.maxInt(u32);

    try utest.runChild(struct {
        pub fn lambda() !void {
            var rgid: linux.gid_t = undefined;
            var egid: linux.gid_t = undefined;
            var sgid: linux.gid_t = undefined;

            try testing.expectEqual(0, linux.setregid(1000, 2000));
            _ = linux.getresgid(&rgid, &egid, &sgid);
            try testing.expectEqual(1000, rgid);
            try testing.expectEqual(2000, egid);

            try testing.expectEqual(0, linux.setregid(nochange, 0));
        }
    });
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
