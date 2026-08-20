// =============================================================
// clone

test "clone behaves like fork when no flags are given" {
    const expected_exit = 42;
    const ret = linux.syscall5(.clone, 0, 0, 0, 0, 0);
    if (ret == 0) {
        // Child: exit immediately.
        linux.exit_group(expected_exit);
    }

    try utest.expectWaitChild(@intCast(ret), expected_exit << 8);
}

// =============================================================
// fork

test "fork" {
    if (comptime !builtin.cpu.arch.isX86()) return error.SkipZigTest;

    const expected_exit = 43;
    const ret = linux.syscall0(.fork);
    if (ret == 0) {
        // Child: exit immediately.
        linux.exit_group(expected_exit);
    }

    try utest.expectWaitChild(@intCast(ret), expected_exit << 8);
}

// =============================================================
// vfork

test "vfork" {
    if (comptime !builtin.cpu.arch.isX86()) return error.SkipZigTest;

    const expected_exit = 44;
    const ret = linux.syscall0(.vfork);
    if (ret == 0) {
        // Child: exit immediately.
        linux.exit_group(expected_exit);
    }

    try utest.expectWaitChild(@intCast(ret), expected_exit << 8);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const utest = @import("utest");
