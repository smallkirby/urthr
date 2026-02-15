/// Context saved during a thread switch.
const SwitchContext = extern struct {
    x29: usize,
    x30: usize,
    x27: usize,
    x28: usize,
    x25: usize,
    x26: usize,
    x23: usize,
    x24: usize,
    x21: usize,
    x22: usize,
    x19: usize,
    x20: usize,
};

/// Initialize the thread stack.
pub fn initStack(stack: []u8, entry: anytype, arg: anytype) []u8 {
    var addr: usize = @intFromPtr(stack.ptr) + stack.len;

    addr -= @sizeOf(IsrContext);
    const ic: *align(16) IsrContext = @ptrFromInt(addr);
    addr -= @sizeOf(SwitchContext);
    const sc: *align(16) SwitchContext = @ptrFromInt(addr);

    // Construct orphan frame.
    ic.* = .{
        .x0 = @intFromPtr(arg),
        .x1 = 0,
        .x2 = 0,
        .x3 = 0,
        .x4 = 0,
        .x5 = 0,
        .x6 = 0,
        .x7 = 0,
        .x8 = 0,
        .x9 = 0,
        .x10 = 0,
        .x11 = 0,
        .x12 = 0,
        .x13 = 0,
        .x14 = 0,
        .x15 = 0,
        .x16 = 0,
        .x17 = 0,
        .x18 = 0,
        .x19 = 0,
        .x20 = 0,
        .x21 = 0,
        .x22 = 0,
        .x23 = 0,
        .x24 = 0,
        .x25 = 0,
        .x26 = 0,
        .x27 = 0,
        .x28 = 0,
        .x29 = 0,
        .x30 = 0,
        ._pad = 0,
        .pc = @intFromPtr(entry),
        .pstate = @bitCast(std.mem.zeroInit(regs.Spsr, .{
            .m_elsp = .el1h,
            .m_es = 0, // aarch64
            .f = false,
            .i = false,
        })),
    };

    // Construct initial switch context.
    sc.* = .{
        .x19 = 0,
        .x20 = 0,
        .x21 = 0,
        .x22 = 0,
        .x23 = 0,
        .x24 = 0,
        .x25 = 0,
        .x26 = 0,
        .x27 = 0,
        .x28 = 0,
        .x29 = 0,
        .x30 = @intFromPtr(&trampoline),
    };

    return stack[0..(addr - @intFromPtr(stack.ptr))];
}

/// Switch context from the old thread to the new thread.
pub extern fn switchContext(old: *usize, new: *const usize) callconv(.c) void;

/// Thread entry trampoline function.
fn trampoline() callconv(.naked) noreturn {
    asm volatile (
        \\
        // Exit pseudo-exception handler using the orphan frame.
        \\bl exit_exception
        // Unreachable.
        \\udf #0
    );
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const regs = @import("register.zig");
const IsrContext = @import("isr.zig").Context;
