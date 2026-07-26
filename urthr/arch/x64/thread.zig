/// Context saved during a thread switch.
const SwitchContext = extern struct {
    r15: usize,
    r14: usize,
    r13: usize,
    r12: usize,
    rbx: usize,
    rbp: usize,
    link: usize,
};

/// Context saved during an interrupt or exception.
const IsrContext = isr.Context;

/// Initialize the thread stack.
pub fn initStack(stack: []u8, entry: anytype, arg: anytype) []u8 {
    const bottom: usize = @intFromPtr(stack.ptr) + stack.len;
    var addr: usize = bottom;

    addr -= @sizeOf(IsrContext);
    const ic: *align(16) IsrContext = @ptrFromInt(addr);
    addr -= @sizeOf(SwitchContext);
    const sc: *SwitchContext = @ptrFromInt(addr);

    // Construct orphan frame.
    const cs = gdt.SegSel{
        .rpl = 0,
        .index = .kernel_cs,
    };
    const ss = gdt.SegSel{
        .rpl = 0,
        .index = .kernel_ds,
    };
    const rflags = std.mem.zeroInit(regs.Rflags, .{
        .ie = true,
    });
    ic.* = std.mem.zeroInit(IsrContext, .{
        .rdi = @intFromPtr(arg),
        .rip = @intFromPtr(entry),
        .cs = @as(u16, @bitCast(cs)),
        .rflags = @as(u64, @bitCast(rflags)),
        .rsp = bottom - 8,
        .ss = @as(u16, @bitCast(ss)),
    });

    // Construct initial switch context.
    sc.* = std.mem.zeroInit(SwitchContext, .{
        .link = @intFromPtr(&trampoline),
    });

    return stack[0 .. addr - @intFromPtr(stack.ptr)];
}

/// Initialize the thread stack for a cloned child process.
pub fn initStackFork(stack: []u8, parent_ctx: *const IsrContext, user_sp: usize) []u8 {
    var addr: usize = @intFromPtr(stack.ptr) + stack.len;

    addr -= @sizeOf(IsrContext);
    const ic: *align(16) IsrContext = @ptrFromInt(addr);
    addr -= @sizeOf(SwitchContext);
    const sc: *SwitchContext = @ptrFromInt(addr);

    // Copy parent's ISR context.
    ic.* = parent_ctx.*;
    ic.rax = 0; // return value for the child.
    ic.rsp = user_sp;

    // Construct initial switch context for the child.
    sc.* = std.mem.zeroInit(SwitchContext, .{
        .link = @intFromPtr(&trampoline),
    });

    return stack[0 .. addr - @intFromPtr(stack.ptr)];
}

/// Get the user stack pointer recorded in the given ISR context.
///
/// Valid only when called from a syscall handler.
pub fn userStackPointerOf(ctx: *const IsrContext) usize {
    return ctx.rsp;
}

/// Get the ISR context saved on the given kernel stack.
///
/// Valid only when called from a syscall handler.
pub fn isrContextOf(kstack: []u8) *IsrContext {
    return @ptrFromInt(@intFromPtr(kstack.ptr) + kstack.len - @sizeOf(IsrContext));
}

/// Switch context from the old thread to the new thread.
pub extern fn switchContext(old: *usize, new: *const usize) callconv(.c) void;

/// Set the thread pointer for TLS.
pub fn setThreadPointer(tp: usize) void {
    am.wrmsr(.fs_base, .{ .addr = tp });
}

/// Drop from Ring-0 to Ring-3 and start executing at the given user PC with the given user SP.
///
/// Does not return.
pub extern fn enterUserland(pc: usize, sp: usize, kstack: usize) callconv(.c) noreturn;

/// Thread entry trampoline function.
fn trampoline() callconv(.naked) noreturn {
    asm volatile (
        \\jmp isrReturn
    );
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const isr = @import("isr.zig");
const gdt = @import("gdt.zig");
const regs = @import("register.zig");
const am = @import("asm.zig");
