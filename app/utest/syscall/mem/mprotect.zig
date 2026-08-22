test "fails with EINVAL for an unaligned address" {
    const ret = linux.mprotect(
        @ptrFromInt(1),
        0x1000,
        .{ .READ = true },
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "succeeds with a zero length" {
    const cur = linux.brk(0);
    const ret = linux.mprotect(
        @ptrFromInt(cur),
        0,
        .{ .READ = true },
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
}

test "changes the protection of an existing anonymous mapping" {
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

test "changes the protection of the sub-range" {
    const page_size = 0x1000;
    const len = page_size * 3;
    const map_ret = mem.mmap(
        0,
        len,
        mem.PROT_READ | mem.PROT_WRITE,
        mem.MAP_PRIVATE | mem.MAP_ANONYMOUS,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(map_ret));
    defer _ = linux.munmap(@ptrFromInt(map_ret), len);

    // Make only the middle page read-only.
    const prot_ret = linux.mprotect(
        @ptrFromInt(map_ret + page_size),
        page_size,
        .{ .READ = true },
    );
    try testing.expectEqual(.SUCCESS, linux.errno(prot_ret));

    // The first and last pages must remain writable.
    const first: [*]u8 = @ptrFromInt(map_ret);
    first[0] = 0x11;
    try testing.expectEqual(@as(u8, 0x11), first[0]);

    const last: [*]u8 = @ptrFromInt(map_ret + 2 * page_size);
    last[0] = 0x22;
    try testing.expectEqual(@as(u8, 0x22), last[0]);

    // The middle page must be read-only.
    try utest.expectRunChildSignaled(linux.SIG.SEGV, map_ret + page_size, struct {
        pub fn lambda(addr: usize) noreturn {
            const ptr: *volatile u8 = @ptrFromInt(addr);
            ptr.* = 1; // SEGV
            unreachable;
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
const mem = utest.mem;
