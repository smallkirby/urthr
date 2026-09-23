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
    // To ensure child does not touch parent's stack, keep it in asm.
    const ret = asm volatile (
        \\
        // vfork syscall
        \\syscall
        \\testq %%rax, %%rax
        // child entry
        \\jnz 1f
        \\movq %[exit_nr], %%rax
        \\movq %[code], %%rdi
        \\syscall
        // parent entry
        \\1:
        : [ret] "={rax}" (-> u64),
        : [nr] "{rax}" (@intFromEnum(linux.SYS.vfork)),
          [exit_nr] "r" (@intFromEnum(linux.SYS.exit_group)),
          [code] "r" (@as(u64, expected_exit)),
        : .{ .rdi = true, .rcx = true, .r11 = true, .memory = true });

    try utest.expectWaitChild(@intCast(ret), expected_exit << 8);
}

// =============================================================
// COW

test "mprotect on an untouched COW-shared page" {
    const page_size = 0x1000;
    const original: u8 = 0x11;
    const modified: u8 = 0x22;

    const map_ret = mem.mmap(
        0,
        page_size,
        mem.PROT_READ | mem.PROT_WRITE,
        mem.MAP_PRIVATE | mem.MAP_ANONYMOUS,
    );
    try testing.expectEqual(.SUCCESS, linux.errno(map_ret));
    defer _ = linux.munmap(@ptrFromInt(map_ret), page_size);

    // Back the page with known contents to ensure the page is COW-ed.
    const ptr: *volatile u8 = @ptrFromInt(map_ret);
    ptr.* = original;

    const fork_ret = linux.fork();
    if (fork_ret == 0) {
        // Read accesses the shared page.
        if (ptr.* != original) linux.exit_group(1);

        // mprotect on the shared page to make it copied.
        const prot_ret = linux.mprotect(
            @ptrFromInt(map_ret),
            page_size,
            .{ .READ = true, .WRITE = true },
        );
        if (linux.errno(prot_ret) != .SUCCESS) linux.exit_group(2);

        ptr.* = modified;
        linux.exit_group(if (ptr.* == modified) 0 else 3);
    }

    try utest.expectWaitChild(@intCast(fork_ret), 0);

    // The parent's own page must be unaffected.
    try testing.expectEqual(original, ptr.*);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const linux = std.os.linux;
const utest = @import("utest");
const mem = utest.mem;
