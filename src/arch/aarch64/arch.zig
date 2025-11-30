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

// =============================================================
// Imports
// =============================================================

// Force evaluate symbols exported but not referenced in Zig.
comptime {
    _ = exception;
}
