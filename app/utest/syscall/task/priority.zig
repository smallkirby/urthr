const prio_process = 0;

test "getpriority returns 20 for the default nice value" {
    try testing.expectEqual(20, getpriority(prio_process, 0));
}

test "setpriority changes the value returned by getpriority" {
    defer _ = setpriority(prio_process, 0, 0);

    try testing.expectEqual(.SUCCESS, linux.errno(setpriority(prio_process, 0, 5)));
    try testing.expectEqual(15, getpriority(prio_process, 0));
    try testing.expectEqual(15, getpriority(prio_process, @intCast(linux.gettid())));
}

test "setpriority clamps the nice value to the valid range" {
    defer _ = setpriority(prio_process, 0, 0);

    try testing.expectEqual(.SUCCESS, linux.errno(setpriority(prio_process, 0, 100)));
    try testing.expectEqual(1, getpriority(prio_process, 0));
    try testing.expectEqual(.SUCCESS, linux.errno(setpriority(prio_process, 0, -100)));
    try testing.expectEqual(40, getpriority(prio_process, 0));
}

test "setpriority fails with EINVAL for an invalid which" {
    try testing.expectEqual(.INVAL, linux.errno(setpriority(99, 0, 0)));
    try testing.expectEqual(.INVAL, linux.errno(getpriority(99, 0)));
}

test "setpriority fails with ESRCH for another process" {
    try testing.expectEqual(.SRCH, linux.errno(setpriority(prio_process, 99999, 0)));
    try testing.expectEqual(.SRCH, linux.errno(getpriority(prio_process, 99999)));
}

test "child inherits the nice value" {
    defer _ = setpriority(prio_process, 0, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(setpriority(prio_process, 0, 7)));

    const ret = linux.syscall5(.clone, 0, 0, 0, 0, 0);
    if (ret == 0) {
        linux.exit_group(@intCast(getpriority(prio_process, 0)));
    }

    try utest.expectWaitChild(@intCast(ret), 13 << 8);
}

// =============================================================
// Helpers
// =============================================================

fn getpriority(which: usize, who: usize) usize {
    return linux.syscall2(.getpriority, which, who);
}

fn setpriority(which: usize, who: usize, prio: isize) usize {
    return linux.syscall3(.setpriority, which, who, @bitCast(prio));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
