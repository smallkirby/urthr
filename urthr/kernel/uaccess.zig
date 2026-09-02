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
pub fn copyFromUser(dst: []u8, uaddr: anytype) Error!void {
    const up = userAddress(uaddr);
    if (!accessOk(up, dst.len)) return Error.Fault;
    if (dst.len == 0) return;

    const remaining = arch.uaccess.copy(
        dst.ptr,
        @as([*]const u8, @ptrFromInt(up)),
        dst.len,
    );
    if (remaining != 0) return Error.Fault;
}

/// Copies data from the kernel buffer into the user address.
///
/// Returns error if the range is invalid or a byte cannot be written.
/// On error, the contents of the user memory are undefined.
pub fn copyToUser(uaddr: anytype, src: []const u8) Error!void {
    const up = userAddress(uaddr);
    if (!accessOk(up, src.len)) return Error.Fault;
    if (src.len == 0) return;

    const remaining = arch.uaccess.copy(
        @as([*]u8, @ptrFromInt(up)),
        src.ptr,
        src.len,
    );
    if (remaining != 0) return Error.Fault;
}

/// Copies a slice of `T` values from the kernel slice into the user address.
pub fn copySliceToUser(comptime T: type, uaddr: anytype, src: []const T) Error!void {
    try copyToUser(userAddress(uaddr), std.mem.sliceAsBytes(src));
}

/// Copies a slice of `T` values from the user address into the kernel slice.
pub fn copySliceFromUser(comptime T: type, dst: []T, uaddr: anytype) Error!void {
    try copyFromUser(std.mem.sliceAsBytes(dst), userAddress(uaddr));
}

/// Copies a NULL-terminated string from the user address.
///
/// Returns the string without the terminating NULL byte.
pub fn copyString(dst: []u8, uaddr: usize) Error![]u8 {
    var done: usize = 0;
    while (done < dst.len) {
        // Not cross page boundary.
        const page_size = urd.mem.page_size;
        const to_page = page_size - ((uaddr + done) & (page_size - 1));
        const want = @min(to_page, dst.len - done);

        // Copy from user space.
        try copyFromUser(dst[done .. done + want], uaddr + done);

        // Find the NULL-terminator.
        if (std.mem.indexOfScalar(u8, dst[done .. done + want], 0)) |rel| {
            return dst[0 .. done + rel];
        }
        done += want;
    }

    // NULL not found.
    return Error.Fault;
}

/// Read a single value of type `T` from user address.
pub fn getUser(comptime T: type, uptr: anytype) Error!T {
    var val: T = undefined;
    try copyFromUser(std.mem.asBytes(&val), userAddress(uptr));
    return val;
}

/// Write a single value of type `T` to user address.
pub fn putUser(comptime T: type, uptr: anytype, val: T) Error!void {
    try copyToUser(userAddress(uptr), std.mem.asBytes(&val));
}

/// Allow access to user-space memory by supervisor mode.
pub fn allowUserAccess() void {
    arch.uaccess.allowUserAccess();
}

/// Disallow access to user-space memory by supervisor mode.
pub fn disallowUserAccess() void {
    arch.uaccess.disallowUserAccess();
}

/// Convert the given value to a user pointer.
fn userAddress(uaddr: anytype) usize {
    return switch (@typeInfo(@TypeOf(uaddr))) {
        .pointer => |pointer| switch (pointer.size) {
            .one, .many, .c => @intFromPtr(uaddr),
            .slice => @intFromPtr(uaddr.ptr),
        },
        .int => uaddr,
        else => unreachable,
    };
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const arch = @import("arch").impl;
const urd = @import("urthr");
