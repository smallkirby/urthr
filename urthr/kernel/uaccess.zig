//! Fault-safe access to user-space memory.
//!
//! These APIs must be called while IRQs are enabled.

pub const Error = error{Fault};

/// Check if the given virtual address range is entirely within the user space.
///
/// A zero-length range is always reported as valid.
pub fn accessOk(uaddr: usize, len: usize) bool {
    if (len == 0) return true;
    const end = std.math.add(usize, uaddr, len) catch return false;
    const user = urd.mem.vmap.user;
    return user.start <= uaddr and end <= user.end;
}

/// Copies data from the user address into the kernel buffer.
///
/// Returns error if the range is invalid or a byte cannot be read.
/// On error, the contents of the destination buffer are undefined.
pub fn copyFromUser(dst: []u8, uaddr: usize) Error!void {
    if (!accessOk(uaddr, dst.len)) return Error.Fault;
    if (dst.len == 0) return;

    const remaining = arch.uaccess.copy(
        dst.ptr,
        @as([*]const u8, @ptrFromInt(uaddr)),
        dst.len,
    );
    if (remaining != 0) return Error.Fault;
}

/// Copies data from the kernel buffer into the user address.
///
/// Returns error if the range is invalid or a byte cannot be written.
/// On error, the contents of the user memory are undefined.
pub fn copyToUser(uaddr: usize, src: []const u8) Error!void {
    if (!accessOk(uaddr, src.len)) return Error.Fault;
    if (src.len == 0) return;

    const remaining = arch.uaccess.copy(
        @as([*]u8, @ptrFromInt(uaddr)),
        src.ptr,
        src.len,
    );
    if (remaining != 0) return Error.Fault;
}

/// Read a single value of type `T` from user address.
pub fn getUser(comptime T: type, uptr: usize) Error!T {
    var val: T = undefined;
    try copyFromUser(std.mem.asBytes(&val), uptr);
    return val;
}

/// Write a single value of type `T` to user address.
pub fn putUser(comptime T: type, uptr: usize, val: T) Error!void {
    try copyToUser(uptr, std.mem.asBytes(&val));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const arch = @import("arch").impl;
const urd = @import("urthr");
