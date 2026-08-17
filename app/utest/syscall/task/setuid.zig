test "setuid drops privilege and blocks escalation" {
    try utest.runChild(struct {
        pub fn lambda() !void {
            // Drop privilege.
            try testing.expectEqual(0, linux.getuid());
            try testing.expectEqual(0, linux.setuid(1000));
            try testing.expectEqual(1000, linux.getuid());
            try testing.expectEqual(1000, linux.geteuid());
            // Cant change EUID to root.
            try testing.expect(0 != linux.setuid(0));
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
