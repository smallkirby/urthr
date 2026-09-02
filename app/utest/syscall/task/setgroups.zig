test "setgroups succeeds when called by root" {
    try utest.runChild(struct {
        pub fn lambda() !void {
            const groups = [_]u32{ 1000, 1001, 1002 };
            try testing.expectEqual(0, linux.setgroups(
                groups.len,
                &groups,
            ));
            try testing.expectEqual(0, linux.setgroups(
                0,
                &groups,
            ));
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
