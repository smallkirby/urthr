pub fn eret() noreturn {
    asm volatile ("eret");
    unreachable;
}

pub fn mrs(comptime reg: SystemReg) reg.Type() {
    return @bitCast(asm volatile (std.fmt.comptimePrint(
            \\mrs %[ret], {s}
        , .{reg.str()})
        : [ret] "=r" (-> switch (@sizeOf(SystemReg.Type(reg))) {
            4 => u32,
            8 => u64,
            else => @compileError("Unsupported system register size."),
          }),
    ));
}

pub fn msr(comptime reg: SystemReg, value: reg.Type()) void {
    asm volatile (std.fmt.comptimePrint(
            \\msr {s}, %[value]
        , .{reg.str()})
        :
        : [value] "r" (@as(switch (@sizeOf(reg.Type())) {
            4 => u32,
            8 => u64,
            else => @compileError("Unsupported system register size."),
          }, @bitCast(value))),
    );
}

/// Read modify write a system register.
pub fn modifySreg(comptime reg: SystemReg, value: anytype) void {
    var now = mrs(reg);
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| {
        @field(now, field.name) = @field(value, field.name);
    }
    msr(reg, now);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const regs = @import("register.zig");
const SystemReg = regs.SystemReg;
