comptime {
    _ = @import("mem/brk.zig");
    _ = @import("mem/mmap.zig");
    _ = @import("mem/mprotect.zig");
    _ = @import("mem/munmap.zig");
}

// Protection flags.
pub const PROT_READ: u64 = 0x1;
pub const PROT_WRITE: u64 = 0x2;
// Mapping flags.
pub const MAP_SHARED: u64 = 0x01;
pub const MAP_PRIVATE: u64 = 0x02;
pub const MAP_FIXED: u64 = 0x10;
pub const MAP_ANONYMOUS: u64 = 0x20;

const fd_none: u64 = @bitCast(@as(i64, -1));

/// Raw mmap with invalid file descriptor.
pub fn mmap(addr: u64, len: u64, prot: u64, flags: u64) usize {
    return std.os.linux.syscall6(
        .mmap,
        addr,
        len,
        prot,
        flags,
        fd_none,
        0,
    );
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
