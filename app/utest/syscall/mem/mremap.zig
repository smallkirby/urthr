test "fails with EINVAL for an unaligned address" {
    const ret = linux.mremap(@ptrFromInt(1), page, page, .{}, null);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "fails with EINVAL when new length is zero" {
    const addr = mem.mmap(0, page, rw, anon);
    try testing.expectEqual(.SUCCESS, linux.errno(addr));
    defer _ = linux.munmap(@ptrFromInt(addr), page);

    const ret = linux.mremap(@ptrFromInt(addr), page, 0, .{}, null);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "fails with EFAULT for an unmapped range" {
    const addr = mem.mmap(0, page, rw, anon);
    try testing.expectEqual(.SUCCESS, linux.errno(addr));
    _ = linux.munmap(@ptrFromInt(addr), page);

    const ret = linux.mremap(@ptrFromInt(addr), page, page * 2, .{
        .MAYMOVE = true,
    }, null);
    try testing.expectEqual(.FAULT, linux.errno(ret));
}

test "shrinks a mapping in place" {
    const addr = mem.mmap(0, page * 2, rw, anon);
    try testing.expectEqual(.SUCCESS, linux.errno(addr));
    defer _ = linux.munmap(@ptrFromInt(addr), page);
    bytes(addr, page)[0] = 0xFF;

    const ret = linux.mremap(@ptrFromInt(addr), page * 2, page, .{}, null);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(addr, ret);
    try testing.expectEqual(0xFF, bytes(addr, page)[0]);
}

test "grows a mapping and preserves contents" {
    const addr = mem.mmap(0, page, rw, anon);
    try testing.expectEqual(.SUCCESS, linux.errno(addr));
    bytes(addr, page)[0] = 0xBB;

    const ret = linux.mremap(@ptrFromInt(addr), page, page * 4, .{
        .MAYMOVE = true,
    }, null);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.munmap(@ptrFromInt(ret), page * 4);

    const new = bytes(ret, page * 4);
    try testing.expectEqual(0xBB, new[0]);
    new[page * 4 - 1] = 0xCC;
    try testing.expectEqual(0xCC, new[page * 4 - 1]);
    try testing.expectEqual(0, new[page]);
}

test "moves a mapping when the adjacent range is occupied" {
    const addr = mem.mmap(0, page * 2, rw, anon);
    try testing.expectEqual(.SUCCESS, linux.errno(addr));
    defer _ = linux.munmap(@ptrFromInt(addr), page * 2);
    bytes(addr, page)[0] = 0xBB;

    // VMA0: P0, P1

    const blocker = mem.mmap(addr + page, page, rw, anon | mem.MAP_FIXED);
    try testing.expectEqual(.SUCCESS, linux.errno(blocker));
    try testing.expectEqual(addr + page, blocker);

    // VMA0: P0
    // VMA1: P1

    const ret = linux.mremap(@ptrFromInt(addr), page, page * 3, .{
        .MAYMOVE = true,
    }, null);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.munmap(@ptrFromInt(ret), page * 3);

    // VMA1: P1
    // VMA2: P2,P3,P4

    try testing.expect(ret != addr);
    try testing.expectEqual(0xBB, bytes(ret, page)[0]);
}

test "fails with ENOMEM when it can't grow in place without MAYMOVE" {
    const addr = mem.mmap(0, page * 2, rw, anon);
    try testing.expectEqual(.SUCCESS, linux.errno(addr));
    defer _ = linux.munmap(@ptrFromInt(addr), page * 2);
    const blocker = mem.mmap(addr + page, page, rw, anon | mem.MAP_FIXED);
    try testing.expectEqual(.SUCCESS, linux.errno(blocker));

    const ret = linux.mremap(@ptrFromInt(addr), page, page * 2, .{}, null);
    try testing.expectEqual(.NOMEM, linux.errno(ret));
}

test "fails with EINVAL for FIXED or DONTUNMAP without MAYMOVE" {
    const addr = mem.mmap(0, page * 4, rw, anon);
    try testing.expectEqual(.SUCCESS, linux.errno(addr));
    defer _ = linux.munmap(@ptrFromInt(addr), page * 4);

    const fixed = linux.mremap(@ptrFromInt(addr), page, page, .{
        .FIXED = true,
    }, @ptrFromInt(addr + page * 2));
    try testing.expectEqual(.INVAL, linux.errno(fixed));
    const dontunmap = linux.mremap(@ptrFromInt(addr), page, page, .{
        .DONTUNMAP = true,
    }, null);
    try testing.expectEqual(.INVAL, linux.errno(dontunmap));
}

test "fails with EINVAL when FIXED destination overlaps the old range" {
    const addr = mem.mmap(0, page * 4, rw, anon);
    try testing.expectEqual(.SUCCESS, linux.errno(addr));
    defer _ = linux.munmap(@ptrFromInt(addr), page * 4);

    const ret = linux.mremap(@ptrFromInt(addr), page * 2, page * 2, .{
        .MAYMOVE = true,
        .FIXED = true,
    }, @ptrFromInt(addr + page));
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "moves a mapping to the FIXED address and replaces the existing mapping" {
    const addr = mem.mmap(0, page * 4, rw, anon);
    try testing.expectEqual(.SUCCESS, linux.errno(addr));
    defer _ = linux.munmap(@ptrFromInt(addr), page * 4);
    bytes(addr, page)[0] = 0xBB;
    bytes(addr + page * 2, page)[0] = 0xCC;

    // Overwrite the existing mapping at the fixed address
    const ret = linux.mremap(@ptrFromInt(addr), page, page, .{
        .MAYMOVE = true,
        .FIXED = true,
    }, @ptrFromInt(addr + page * 2));
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(addr + page * 2, ret);
    try testing.expectEqual(0xBB, bytes(ret, page)[0]);

    // The old range is no longer mapped.
    const again = linux.mremap(@ptrFromInt(addr), page, page, .{
        .MAYMOVE = true,
    }, null);
    try testing.expectEqual(.FAULT, linux.errno(again));
}

test "moves and grows a mapping to the FIXED address" {
    const addr = mem.mmap(0, page * 8, rw, anon);
    try testing.expectEqual(.SUCCESS, linux.errno(addr));
    defer _ = linux.munmap(@ptrFromInt(addr), page * 8);
    bytes(addr, page)[0] = 0xBB;

    const ret = linux.mremap(@ptrFromInt(addr), page, page * 3, .{
        .MAYMOVE = true,
        .FIXED = true,
    }, @ptrFromInt(addr + page * 4));
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    try testing.expectEqual(addr + page * 4, ret);
    try testing.expectEqual(0xBB, bytes(ret, page)[0]);
    bytes(ret, page * 3)[page * 3 - 1] = 1;
}

test "fails with EINVAL for DONTUNMAP with different sizes" {
    const addr = mem.mmap(0, page * 2, rw, anon);
    try testing.expectEqual(.SUCCESS, linux.errno(addr));
    defer _ = linux.munmap(@ptrFromInt(addr), page * 2);

    const ret = linux.mremap(@ptrFromInt(addr), page, page * 2, .{
        .MAYMOVE = true,
        .DONTUNMAP = true,
    }, null);
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "keeps the old range mapped with DONTUNMAP" {
    const addr = mem.mmap(0, page, rw, anon);
    try testing.expectEqual(.SUCCESS, linux.errno(addr));
    defer _ = linux.munmap(@ptrFromInt(addr), page);
    bytes(addr, page)[0] = 0xBB;

    const ret = linux.mremap(@ptrFromInt(addr), page, page, .{
        .MAYMOVE = true,
        .DONTUNMAP = true,
    }, null);
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.munmap(@ptrFromInt(ret), page);

    try testing.expect(ret != addr);
    try testing.expectEqual(0xBB, bytes(ret, page)[0]);
    // New page is allocated and should be zero-initialized.
    try testing.expectEqual(0, bytes(addr, page)[0]);
}

// =============================================================
// Helpers
// =============================================================

const page = 0x1000;
const rw = mem.PROT_READ | mem.PROT_WRITE;
const anon = mem.MAP_PRIVATE | mem.MAP_ANONYMOUS;

fn bytes(addr: usize, len: usize) []u8 {
    return @as([*]u8, @ptrFromInt(addr))[0..len];
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
const mem = utest.mem;
