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

/// Whether FEAT_PAN is implemented and usable.
export var pan_usable: u8 = 0;
/// Whether support for PAN has been probed.
var pan_probed: bool = false;

/// Probe FEAT_PAN once and cache the result.
pub fn probePan() void {
    if (!pan_probed) {
        @branchHint(.unlikely);
        pan_probed = true;
        pan_usable = @intFromBool(am.mrs(.id_aa64mmfr1_el1).pan != 0);
    }

    if (pan_usable == 0) {
        return;
    }

    am.modifySreg(.sctlr_el1, .{ .span = false });
    am.isb();
    asm volatile ("msr PAN, #1" ::: .{ .memory = true });
}

/// Allow access to user-space memory by supervisor mode.
pub fn allowUserAccess() void {
    if (!pan_probed) {
        @branchHint(.unlikely);
        probePan();
    }
    if (pan_usable == 0) {
        return;
    }
    asm volatile ("msr PAN, #0" ::: .{ .memory = true });
}

/// Disallow access to user-space memory by supervisor mode.
pub fn disallowUserAccess() void {
    if (pan_usable == 0) {
        return;
    }
    asm volatile ("msr PAN, #1" ::: .{ .memory = true });
}

// =============================================================
// Imports
// =============================================================

const am = @import("asm.zig");
