pub const exception = @import("isr.zig");
pub const mmu = @import("mmu.zig");

/// Execute a single NOP instruction.
pub fn nop() void {
    asm volatile ("nop");
}

/// Halt the CPU until the next interrupt.
pub fn halt() void {
    asm volatile ("wfi");
}

/// Translate the given virtual address to physical address.
pub fn translate(virt: usize) usize {
    // TODO: should check the fault status
    // TODO: should strip the bottom bits
    return asm volatile (
        \\at S1E1R, %[virt]
        \\isb
        \\mrs %[out], PAR_EL1
        : [out] "=r" (-> u64),
        : [virt] "r" (virt),
        : .{ .memory = true });
}

/// Exception APIs.
pub const intr = struct {
    /// Mask all exceptions.
    pub fn maskAll() u64 {
        const daif = am.mrs(.daif);
        am.msr(.daif, .{
            .d = daif.d,
            .a = daif.a,
            .i = true,
            .f = true,
        });
        am.isb();

        return @bitCast(daif);
    }

    /// Set exception mask.
    pub fn setMask(daif: u64) void {
        am.msr(.daif, @bitCast(daif));
    }
};

// =============================================================
// Imports
// =============================================================

// Force evaluate symbols exported but not referenced in Zig.
comptime {
    _ = exception;
}

const am = @import("asm.zig");
