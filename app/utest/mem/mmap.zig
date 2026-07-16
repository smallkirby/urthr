test "mmap fails with EINVAL when length is zero" {
    const ret = mem.mmap(
        0,
        0,
        mem.PROT_READ | mem.PROT_WRITE,
        mem.MAP_PRIVATE | mem.MAP_ANONYMOUS,
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "mmap fails with EINVAL when neither MAP_SHARED nor MAP_PRIVATE is set" {
    const ret = mem.mmap(
        0,
        0x1000,
        mem.PROT_READ | mem.PROT_WRITE,
        mem.MAP_ANONYMOUS,
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "mmap fails with EINVAL for an unaligned MAP_FIXED address" {
    const ret = mem.mmap(
        1,
        0x1000,
        mem.PROT_READ | mem.PROT_WRITE,
        mem.MAP_PRIVATE | mem.MAP_ANONYMOUS | mem.MAP_FIXED,
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "tag:SKIP mmap with a file descriptor succeeds" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const ret = linux.syscall6(
        .mmap,
        0,
        0x1000,
        mem.PROT_READ,
        mem.MAP_PRIVATE,
        @intCast(fd),
        0,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    _ = linux.munmap(@ptrFromInt(ret), 0x1000);
}

test "mmap with MAP_FIXED succeeds at a free page-aligned address" {
    const len = 0x1000;

    // Get a valid, currently-free page-aligned address via a normal mapping.
    const probe = mem.mmap(
        0,
        len,
        mem.PROT_READ,
        mem.MAP_PRIVATE | mem.MAP_ANONYMOUS,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(probe));
    try testing.expectEqual(.SUCCESS, linux.errno(linux.munmap(@ptrFromInt(probe), len)));

    const ret = mem.mmap(
        probe,
        len,
        mem.PROT_READ | mem.PROT_WRITE,
        mem.MAP_PRIVATE | mem.MAP_ANONYMOUS | mem.MAP_FIXED,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(probe, ret);
    defer _ = linux.munmap(@ptrFromInt(ret), len);

    const ptr: [*]u8 = @ptrFromInt(ret);
    ptr[0] = 0x7;
    try testing.expectEqual(@as(u8, 0x7), ptr[0]);
}

test "an anonymous private mapping is readable and writable" {
    const len = 0x1000;
    const ret = mem.mmap(
        0,
        len,
        mem.PROT_READ | mem.PROT_WRITE,
        mem.MAP_PRIVATE | mem.MAP_ANONYMOUS,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));

    const ptr: [*]u8 = @ptrFromInt(ret);
    ptr[0] = 0x42;
    try testing.expectEqual(@as(u8, 0x42), ptr[0]);

    const unmap_ret = linux.munmap(ptr, len);
    try testing.expectEqual(.SUCCESS, linux.errno(unmap_ret));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("../utest.zig");
const mem = utest.mem;
