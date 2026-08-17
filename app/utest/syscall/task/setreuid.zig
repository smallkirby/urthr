test "setreuid drops privilege and blocks escalation" {
    const nochange = std.math.maxInt(u32);

    try utest.runChild(struct {
        pub fn lambda() !void {
            var ruid: linux.uid_t = undefined;
            var euid: linux.uid_t = undefined;
            var suid: linux.uid_t = undefined;

            // Drop privilege.
            try testing.expectEqual(0, linux.setreuid(
                1000,
                1000,
            ));
            _ = linux.getresuid(&ruid, &euid, &suid);
            try testing.expectEqual(1000, ruid);
            try testing.expectEqual(1000, euid);
            try testing.expectEqual(1000, suid);

            // Can't change EUID to root.
            try testing.expect(0 != linux.setreuid(nochange, 0));
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
