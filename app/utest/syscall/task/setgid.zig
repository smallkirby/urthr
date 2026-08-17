test "setgid changes GID and EGID when called by root" {
    try utest.runChild(struct {
        pub fn lambda() !void {
            try testing.expectEqual(0, linux.getgid());
            try testing.expectEqual(0, linux.setgid(1000));
            try testing.expectEqual(1000, linux.getgid());
            try testing.expectEqual(1000, linux.getegid());
            try testing.expectEqual(0, linux.setgid(0));
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
