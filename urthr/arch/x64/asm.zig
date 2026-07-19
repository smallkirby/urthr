pub fn rdmsr(comptime msr: SystemReg) regs.Type(msr) {
    var eax: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile (
        \\rdmsr
        : [eax] "={eax}" (eax),
          [edx] "={edx}" (edx),
        : [msr] "{ecx}" (regs.address(msr)),
        : .{});

    const value = (@as(u64, edx) << 32) | eax;
    return @bitCast(value);
}

pub fn wrmsr(comptime msr: SystemReg, value: regs.Type(msr)) void {
    const val: u64 = @bitCast(value);
    const eax: u32 = @truncate(val);
    const edx: u32 = @truncate(val >> 32);
    asm volatile (
        \\wrmsr
        :
        : [msr] "{ecx}" (regs.address(msr)),
          [eax] "{eax}" (eax),
          [edx] "{edx}" (edx),
        : .{});
}

// =============================================================
// Imports
// =============================================================

const regs = @import("register.zig");
const SystemReg = regs.SystemReg;
