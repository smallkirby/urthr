export fn setupHead() callconv(.c) void {
    // Enable FSBASE / GSBASE instructions.
    // TODO: check CPUID to see if supported.
    {
        var cr4 = asm volatile (
            \\mov %%cr4, %[out]
            : [out] "=r" (-> regs.Cr4),
            :
            : .{ .memory = true });
        cr4.fsgsbase = true;
        asm volatile (
            \\mov %[in], %%cr4
            :
            : [in] "r" (cr4),
            : .{ .memory = true });
    }
}

// =============================================================
// Imports
// =============================================================

const regs = @import("register.zig");
