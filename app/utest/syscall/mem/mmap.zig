test "fails with EINVAL when length is zero" {
    const ret = mem.mmap(
        0,
        0,
        mem.PROT_READ | mem.PROT_WRITE,
        mem.MAP_PRIVATE | mem.MAP_ANONYMOUS,
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "fails with EINVAL when neither MAP_SHARED nor MAP_PRIVATE is set" {
    const ret = mem.mmap(
        0,
        0x1000,
        mem.PROT_READ | mem.PROT_WRITE,
        mem.MAP_ANONYMOUS,
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "fails with EINVAL for an unaligned MAP_FIXED address" {
    const ret = mem.mmap(
        1,
        0x1000,
        mem.PROT_READ | mem.PROT_WRITE,
        mem.MAP_PRIVATE | mem.MAP_ANONYMOUS | mem.MAP_FIXED,
    );
    try testing.expectEqual(.INVAL, linux.errno(ret));
}

test "fails with ENOSYS for MAP_SHARED" {
    const ret = mem.mmap(
        0,
        0x1000,
        mem.PROT_READ | mem.PROT_WRITE,
        mem.MAP_SHARED | mem.MAP_ANONYMOUS,
    );
    try testing.expectEqual(.NOSYS, linux.errno(ret));
}

test "with a file descriptor succeeds and reads the file's content lazily" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    // Read the same bytes normally, to compare against the mapped content.
    var expected: [0x1000]u8 = undefined;
    const nread = linux.read(@intCast(fd), &expected, expected.len);
    try testing.expectEqual(.SUCCESS, linux.errno(nread));

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
    defer _ = linux.munmap(@ptrFromInt(ret), 0x1000);

    // First access triggers the page fault handler, which reads the page from the file.
    const ptr: [*]const u8 = @ptrFromInt(ret);
    try testing.expectEqualSlices(u8, expected[0..nread], ptr[0..nread]);
}

test "with a file descriptor and a non-zero offset maps the correct region" {
    const fd = linux.open(utest.myname, .{}, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));

    const offset = 0x1000;
    const seek_ret = linux.lseek(@intCast(fd), offset, linux.SEEK.SET);
    try testing.expectEqual(.SUCCESS, linux.errno(seek_ret));

    var expected: [0x1000]u8 = undefined;
    const nread = linux.read(@intCast(fd), &expected, expected.len);
    try testing.expectEqual(.SUCCESS, linux.errno(nread));

    const ret = linux.syscall6(
        .mmap,
        0,
        0x1000,
        mem.PROT_READ,
        mem.MAP_PRIVATE,
        @intCast(fd),
        offset,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.munmap(@ptrFromInt(ret), 0x1000);

    const ptr: [*]const u8 = @ptrFromInt(ret);
    try testing.expectEqualSlices(u8, expected[0..nread], ptr[0..nread]);
}

test "fails with EBADF for an invalid file descriptor" {
    const ret = linux.syscall6(
        .mmap,
        0,
        0x1000,
        mem.PROT_READ,
        mem.MAP_PRIVATE,
        @as(u64, @bitCast(@as(i64, -2))),
        0,
    );
    try testing.expectEqual(.BADF, linux.errno(ret));
}

test "with MAP_FIXED succeeds at a free page-aligned address" {
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

test "an anonymous private mapping is zero-filled on first access" {
    const len = 0x3000;
    const ret = mem.mmap(
        0,
        len,
        mem.PROT_READ | mem.PROT_WRITE,
        mem.MAP_PRIVATE | mem.MAP_ANONYMOUS,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.munmap(@ptrFromInt(ret), len);

    const ptr: [*]u8 = @ptrFromInt(ret);
    for (0..len) |i| {
        try testing.expectEqual(@as(u8, 0), ptr[i]);
    }
}

test "accessing an address outside of any mapping raises SIGSEGV" {
    try utest.expectRunChildSignaled(linux.SIG.SEGV, 0, struct {
        pub fn lambda(addr: usize) noreturn {
            const ptr: *allowzero volatile u8 = @ptrFromInt(addr);
            ptr.* = 1; // SEGV
            unreachable;
        }
    });
}

test "writing to a read-only mapping raises SIGSEGV" {
    const len = 0x1000;
    const ret = mem.mmap(
        0,
        len,
        mem.PROT_READ,
        mem.MAP_PRIVATE | mem.MAP_ANONYMOUS,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(ret));
    defer _ = linux.munmap(@ptrFromInt(ret), len);

    try utest.expectRunChildSignaled(linux.SIG.SEGV, ret, struct {
        pub fn lambda(addr: usize) noreturn {
            const ptr: *volatile u8 = @ptrFromInt(addr); // SEGV
            ptr.* = 1;
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
