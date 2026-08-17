test "setresuid sets real, effective, and saved UID" {
    const nochange = std.math.maxInt(u32);

    try utest.runChild(struct {
        pub fn lambda() !void {
            var ruid: linux.uid_t = undefined;
            var euid: linux.uid_t = undefined;
            var suid: linux.uid_t = undefined;

            try testing.expectEqual(0, linux.setresuid(
                1000,
                2000,
                3000,
            ));
            _ = linux.getresuid(&ruid, &euid, &suid);
            try testing.expectEqual(1000, ruid);
            try testing.expectEqual(2000, euid);
            try testing.expectEqual(3000, suid);

            // Unprivileged now.
            try testing.expect(0 != linux.setresuid(0, nochange, nochange));
            try testing.expectEqual(0, linux.setresuid(
                3000,
                nochange,
                nochange,
            ));
            _ = linux.getresuid(&ruid, &euid, &suid);
            try testing.expectEqual(3000, ruid);
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
