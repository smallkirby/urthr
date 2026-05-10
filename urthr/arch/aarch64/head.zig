/// Setup EL1 system registers for this core.
export fn setupEl1() callconv(.c) void {
    var cpacr = am.mrs(.cpacr_el1);
    cpacr.fpen = 0b11; // Enable FP/SIMD at EL0 and EL1.
    am.msr(.cpacr_el1, cpacr);
}

// =============================================================
// Imports
// =============================================================

const am = @import("asm.zig");
