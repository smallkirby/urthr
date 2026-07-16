test "fails with EINVAL for an unaligned address" {
    const ret = linux.munmap(@ptrFromInt(1), 0x1000);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "fails with EINVAL when length is zero" {
    const len = 0x1000;
    const map_ret = mem.mmap(
        0,
        len,
        mem.PROT_READ,
        mem.MAP_PRIVATE | mem.MAP_ANONYMOUS,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(map_ret));
    defer _ = linux.munmap(@ptrFromInt(map_ret), len);

    const ret = linux.munmap(@ptrFromInt(map_ret), 0);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "fails with EINVAL for a length that is not page-aligned" {
    const len = 0x1000;
    const map_ret = mem.mmap(
        0,
        len,
        mem.PROT_READ,
        mem.MAP_PRIVATE | mem.MAP_ANONYMOUS,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(map_ret));
    defer _ = linux.munmap(@ptrFromInt(map_ret), len);

    const ret = linux.munmap(@ptrFromInt(map_ret), 1);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
const mem = utest.mem;
