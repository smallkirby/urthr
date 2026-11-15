/// Context saved during a thread switch.
const SwitchContext = extern struct {
    ra: usize,
    s0: usize,
    s1: usize,
    s2: usize,
    s3: usize,
    s4: usize,
    s5: usize,
    s6: usize,
    s7: usize,
    s8: usize,
    s9: usize,
    s10: usize,
    s11: usize,
    _pad: usize,
};

/// Initialize the thread stack.
pub fn initStack(stack: []u8, entry: anytype, arg: anytype) []u8 {
    var addr: usize = @intFromPtr(stack.ptr) + stack.len;

    addr -= @sizeOf(IsrContext);
    const ic: *align(16) IsrContext = @ptrFromInt(addr);
    addr -= @sizeOf(SwitchContext);
    const sc: *align(16) SwitchContext = @ptrFromInt(addr);

    // Construct orphan frame.
    ic.* = std.mem.zeroInit(IsrContext, .{
        .a0 = @intFromPtr(arg),
        .sepc = @intFromPtr(entry),
        .sstatus = std.mem.zeroInit(regs.Sstatus, .{
            .spp = .supervisor,
            .spie = true,
        }),
    });

    // Construct initial switch context.
    sc.* = std.mem.zeroInit(SwitchContext, .{
        .ra = @intFromPtr(&trampoline),
    });

    return stack[0..(addr - @intFromPtr(stack.ptr))];
}

/// Initialize the thread stack for a cloned child process.
pub fn initStackFork(stack: []u8, parent_ctx: *const IsrContext, user_sp: usize, tls: ?usize) []u8 {
    var addr: usize = @intFromPtr(stack.ptr) + stack.len;

    addr -= @sizeOf(IsrContext);
    const ic: *align(16) IsrContext = @ptrFromInt(addr);
    addr -= @sizeOf(SwitchContext);
    const sc: *align(16) SwitchContext = @ptrFromInt(addr);

    // Copy parent's ISR context.
    ic.* = parent_ctx.*;
    ic.a0 = 0; // return value for the child.
    ic.sp = user_sp;
    ic.tp = tls orelse parent_ctx.tp;

    // Construct initial switch context for the child.
    sc.* = std.mem.zeroInit(SwitchContext, .{
        .ra = @intFromPtr(&trampoline),
    });

    return stack[0..(addr - @intFromPtr(stack.ptr))];
}

/// Layout of the saved FPU state.
pub const FpuState = fpu.State;

/// Initialize FPU state.
///
/// Returns the pointer to the initialized FPU state.
pub fn initFpu(allocator: Allocator) Allocator.Error!*anyopaque {
    return fpu.initState(allocator);
}

/// Release the FPU state.
pub fn deinitFpu(state: *anyopaque, allocator: Allocator) void {
    fpu.deinitState(state, allocator);
}

/// Save the FPU state of the current thread into the given region.
pub fn saveFpu(state: *anyopaque) void {
    fpu.saveState(state);
}

/// Restore the FPU state of the current thread using the given saved state.
pub fn restoreFpu(state: *anyopaque) void {
    fpu.restoreState(state);
}

/// Get the size in bytes of the FPU state.
pub fn getFpuStateSize() usize {
    return fpu.getStateSize();
}

/// Get the user stack pointer recorded in the given ISR context.
///
/// Valid only when called from a syscall handler.
pub fn userStackPointerOf(ctx: *const IsrContext) usize {
    return ctx.sp;
}

/// Get the ISR context saved on the given kernel stack.
///
/// Valid only when called from a syscall handler.
pub fn isrContextOf(kstack: []u8) *IsrContext {
    return @ptrFromInt(@intFromPtr(kstack.ptr) + kstack.len - @sizeOf(IsrContext));
}

/// Get the context saved at the top of the current thread's kernel stack.
///
/// Valid only while the thread is handling a trap taken from U-mode,
/// or before the thread enters U-mode for the first time.
fn userContext() *IsrContext {
    return @ptrFromInt(isr.getKernelStack() - @sizeOf(IsrContext));
}

/// Switch context from the calling thread to the new thread.
///
/// Must be called while IRQ disabled.
///
/// Returns the pointer to the previous thread's context.
pub fn switchContext(oldsp: *usize, newsp: *const usize, kstack: usize, th: *anyopaque, _: ?*anyopaque) *anyopaque {
    isr.setKernelStack(kstack);
    return switchContextAsm(oldsp, newsp, th);
}
extern fn switchContextAsm(oldsp: *usize, newsp: *const usize, th: *anyopaque) callconv(.c) *anyopaque;

/// Set the thread pointer for TLS.
pub fn setThreadPointer(tp: usize) void {
    userContext().tp = tp;
}

/// Drop from S-mode to U-mode and start executing at the given user PC with the given user SP.
///
/// Does not return.
pub fn enterUserland(pc: usize, sp: usize, kstack: usize) noreturn {
    // Disable IRQs.
    _ = arch.intr.maskAll();

    // Set kernel stack for the trap handler.
    isr.setKernelStack(kstack);

    const sstatus = std.mem.zeroInit(regs.Sstatus, .{
        .spp = .user,
        .spie = true,
        .fs = .initial,
        .uxl = .@"64",
    });
    enterUserlandAsm(pc, sp, userContext().tp, @bitCast(sstatus));
}
extern fn enterUserlandAsm(pc: usize, sp: usize, tp: usize, sstatus: usize) callconv(.c) noreturn;

/// Thread entry trampoline function.
fn trampoline() callconv(.naked) noreturn {
    asm volatile (
        \\
        // a0: context of switched-out thread
        \\call onSwitchedIn
        // Exit pseudo-trap handler using the orphan frame.
        \\tail exit_exception
    );
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const arch = @import("arch.zig");
const regs = @import("register.zig");
const isr = @import("isr.zig");
const IsrContext = isr.Context;
const fpu = @import("fpu.zig");
