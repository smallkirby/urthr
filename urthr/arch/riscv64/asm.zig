/// Read a CSR.
pub fn csrr(comptime reg: Csr) regs.Type(reg) {
    return @bitCast(asm volatile (std.fmt.comptimePrint(
            \\csrr %[ret], {s}
        , .{@tagName(reg)})
        : [ret] "=r" (-> switch (@sizeOf(regs.Type(reg))) {
            8 => u64,
            else => @compileError("Unsupported system register size."),
          }),
    ));
}

/// Read a system register and return it as an integer.
pub fn mrsi(comptime reg: Csr) u64 {
    const IntR = @Int(.unsigned, @bitSizeOf(regs.Type(reg)));
    return @as(IntR, @bitCast(csrr(reg)));
}

/// Write a CSR.
pub fn csrw(comptime reg: Csr, value: regs.Type(reg)) void {
    asm volatile (std.fmt.comptimePrint(
            \\csrw {s}, %[value]
        , .{@tagName(reg)})
        :
        : [value] "r" (@as(switch (@sizeOf(regs.Type(reg))) {
            8 => u64,
            else => @compileError("Unsupported system register size."),
          }, @bitCast(value))),
        : .{ .memory = true });
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const regs = @import("register.zig");
const Csr = regs.Csr;
