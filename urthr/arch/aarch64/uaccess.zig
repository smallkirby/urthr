//! Fault-safe primitive to access to user-space memory.

/// Copies data between user and kernel memory.
///
/// Returns the number of bytes that could not be copied.
extern fn __uaccess_copy(dst: [*]u8, src: [*]const u8, len: usize) usize;

/// Start of the faultable instruction region.
extern const __uaccess_copy_faultable_begin: *void;
/// End of the faultable instruction region.
extern const __uaccess_copy_faultable_end: *void;
/// Landing pad that returns the remaining byte count on fault.
extern const __uaccess_copy_fixup: *void;

/// Copy the given length of bytes from the source to the destination buffer.
///
/// Returns the number of bytes that could not be copied.
pub fn copy(dst: [*]u8, src: [*]const u8, len: usize) usize {
    return __uaccess_copy(dst, src, len);
}

/// If the faulting instruction is inside the faultable region, return the address of the fixup landing pad.
/// Otherwise, return null.
pub fn fixupFor(fault_pc: usize) ?usize {
    const begin = @intFromPtr(&__uaccess_copy_faultable_begin);
    const end = @intFromPtr(&__uaccess_copy_faultable_end);
    if (begin <= fault_pc and fault_pc < end) {
        return @intFromPtr(&__uaccess_copy_fixup);
    } else {
        return null;
    }
}

/// Allow access to user-space memory by supervisor mode.
///
/// TODO: use PAN
pub fn allowUserAccess() void {}

/// Disallow access to user-space memory by supervisor mode.
///
/// TODO: use PAN
pub fn disallowUserAccess() void {}
