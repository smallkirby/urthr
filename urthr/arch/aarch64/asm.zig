pub fn eret() noreturn {
    asm volatile ("eret");
    unreachable;
}

const DsbOption = enum {
    sy,
    ish,
    nsh,
    osh,
};

pub fn dsb(option: DsbOption) void {
    switch (option) {
        .sy => asm volatile ("dsb sy"),
        .ish => asm volatile ("dsb ish"),
        .nsh => asm volatile ("dsb nsh"),
        .osh => asm volatile ("dsb osh"),
    }
}

pub fn isb() void {
    asm volatile ("isb");
}

pub fn mrs(comptime reg: SystemReg) reg.Type() {
    return @bitCast(asm volatile (std.fmt.comptimePrint(
            \\mrs %[ret], {s}
        , .{reg.str()})
        : [ret] "=r" (-> switch (@sizeOf(reg.Type())) {
            4 => u32,
            8 => u64,
            else => @compileError("Unsupported system register size."),
          }),
    ));
}

/// Read a system register and return integer value.
pub fn mrsi(comptime reg: SystemReg) u64 {
    const IntR = std.meta.Int(.unsigned, @bitSizeOf(reg.Type()));
    return @as(IntR, @bitCast(mrs(reg)));
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

pub fn smc(arg0: u64, arg1: u64, arg2: u64, arg3: u64) u64 {
    return asm volatile (
        \\mov x0, %[x0]
        \\mov x1, %[x1]
        \\mov x2, %[x2]
        \\mov x3, %[x3]
        \\smc #0
        : [ret] "={x0}" (-> u64),
        : [x0] "r" (arg0),
          [x1] "r" (arg1),
          [x2] "r" (arg2),
          [x3] "r" (arg3),
        : .{
          .x4 = true,
          .x5 = true,
          .x6 = true,
          .x7 = true,
          .x8 = true,
          .x9 = true,
          .x10 = true,
          .x11 = true,
          .x12 = true,
          .x13 = true,
          .x14 = true,
          .memory = true,
        });
}

pub fn wfe() void {
    asm volatile ("wfe");
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const regs = @import("register.zig");
const SystemReg = regs.SystemReg;
