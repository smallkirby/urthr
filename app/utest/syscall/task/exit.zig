test "exit" {
    const expected_exit = 45;
    try utest.expectRunChild(expected_exit << 8, struct {
        pub fn lambda(_: usize) noreturn {
            _ = linux.syscall1(.exit, expected_exit);
            unreachable;
        }
    });
}

test "exit truncates the code to 8 bits" {
    const expected_exit: i32 = -1;
    try utest.expectRunChild(0xFF00, struct {
        pub fn lambda(_: usize) noreturn {
            linux.exit(expected_exit);
        }
    });
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const linux = std.os.linux;
const utest = @import("utest");
