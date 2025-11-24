/// Execute a single NOP instruction.
pub fn nop() void {
    asm volatile ("nop");
}

// =============================================================
// Imports
// =============================================================

// Force evaluate symbols exported but not referenced in Zig.
comptime {
    _ = @import("entry.zig");
}
