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

/// Read a CSR and return it as an integer.
pub fn csrri(comptime reg: Csr) u64 {
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

/// Set bits in a CSR.
pub fn csrs(comptime reg: Csr, value: anytype) void {
    const T = regs.Type(reg);
    const v = std.mem.zeroInit(T, value);
    asm volatile (std.fmt.comptimePrint(
            \\csrs {s}, %[value]
        , .{@tagName(reg)})
        :
        : [value] "r" (@as(usize, @bitCast(v))),
        : .{ .memory = true });
}

/// Clear bits in a CSR.
pub fn csrc(comptime reg: Csr, value: anytype) void {
    const T = regs.Type(reg);
    const v = std.mem.zeroInit(T, value);
    asm volatile (std.fmt.comptimePrint(
            \\csrc {s}, %[value]
        , .{@tagName(reg)})
        :
        : [value] "r" (@as(usize, @bitCast(v))),
        : .{ .memory = true });
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const regs = @import("register.zig");
const Csr = regs.Csr;
