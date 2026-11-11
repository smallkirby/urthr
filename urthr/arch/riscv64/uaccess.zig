//! Fault-safe primitive to access to user-space memory.

const todo = "TODO: RISC-V: uaccess not supported yet";

/// Copy the given length of bytes from the source to the destination buffer.
///
/// Returns the number of bytes that could not be copied.
pub fn copy(_: [*]u8, _: [*]const u8, _: usize) usize {
    @panic(todo);
}

/// If the faulting instruction is inside the faultable region, return the address of the fixup landing pad.
/// Otherwise, return null.
pub fn fixupFor(_: usize) ?usize {
    @panic(todo);
}

/// Allow access to user-space memory by supervisor mode.
pub fn allowUserAccess() void {
    @panic(todo);
}

/// Disallow access to user-space memory by supervisor mode.
pub fn disallowUserAccess() void {
    @panic(todo);
}
