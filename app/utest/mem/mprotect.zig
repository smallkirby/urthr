test "mprotect fails with EINVAL for an unaligned address" {
    const ret = linux.mprotect(
        @ptrFromInt(1),
        0x1000,
        .{ .READ = true },
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "mprotect succeeds with a zero length" {
    const cur = linux.brk(0);
    const ret = linux.mprotect(
        @ptrFromInt(cur),
        0,
        .{ .READ = true },
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

test "mprotect changes the protection of an existing anonymous mapping" {
    const len = 0x1000;
    const map_ret = mem.mmap(
        0,
        len,
        mem.PROT_READ,
        mem.MAP_PRIVATE | mem.MAP_ANONYMOUS,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(map_ret));
    defer _ = linux.munmap(@ptrFromInt(map_ret), len);

    const prot_ret = linux.mprotect(
        @ptrFromInt(map_ret),
        len,
        .{ .READ = true, .WRITE = true },
    );
    try testing.expectEqual(.SUCCESS, linux.errno(prot_ret));

    const ptr: [*]u8 = @ptrFromInt(map_ret);
    ptr[0] = 0x99;
    try testing.expectEqual(@as(u8, 0x99), ptr[0]);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
const mem = utest.mem;
