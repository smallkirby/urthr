/// Kernel entry point.
extern fn kmain() callconv(.c) noreturn;
/// Physical address of the bottom of the boot stack.
///
/// This variable is defined in the linker script.
extern const _boot_stack: *void;

/// Zig entry point directly called from assembly `entry.S`.
///
/// This function is called in EL2 with MMU disabled.
pub export fn kinit() callconv(.c) noreturn {
    am.modifySreg(.hcr_el2, .{
        .rw = true, // set EL1 to AArch64
    });

    am.msr(.spsr_el2, std.mem.zeroInit(regs.Spsr, .{
        // EL1 using SP_EL1.
        .m_elsp = .el1h,
        // Mask exceptions.
        .d = true,
        .a = true,
        .i = true,
        .f = true,
    }));

    // Set return address and SP.
    am.msr(.elr_el2, .{ .addr = @intFromPtr(&kmain) });
    am.msr(.sp_el1, .{ .addr = @intFromPtr(&_boot_stack) });

    // Jump to kmain in EL1.
    am.eret();
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const am = @import("asm.zig");
const regs = @import("register.zig");
