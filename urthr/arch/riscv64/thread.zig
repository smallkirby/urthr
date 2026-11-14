const todo = "TODO: RISC-V: thread is not supported yet";

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
pub fn initStackFork(_: []u8, _: *const IsrContext, _: usize, _: ?usize) []u8 {
    @panic(todo);
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
pub fn userStackPointerOf(_: *const IsrContext) usize {
    @panic(todo);
}

/// Get the ISR context saved on the given kernel stack.
///
/// Valid only when called from a syscall handler.
pub fn isrContextOf(_: []u8) *IsrContext {
    @panic(todo);
}

/// Switch context from the calling thread to the new thread.
///
/// Must be called while IRQ disabled.
///
/// Returns the pointer to the previous thread's context.
pub fn switchContext(oldsp: *usize, newsp: *const usize, _: usize, th: *anyopaque, _: ?*anyopaque) *anyopaque {
    return switchContextAsm(oldsp, newsp, th);
}
extern fn switchContextAsm(oldsp: *usize, newsp: *const usize, th: *anyopaque) callconv(.c) *anyopaque;

/// Set the thread pointer for TLS.
pub fn setThreadPointer(_: usize) void {
    @panic(todo);
}

/// Drop from S-mode to U-mode and start executing at the given user PC with the given user SP.
///
/// Does not return.
pub fn enterUserland(_: usize, _: usize, _: usize) noreturn {
    @panic(todo);
}

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
const common = @import("common");
const rtt = common.rtt;
const regs = @import("register.zig");
const IsrContext = @import("isr.zig").Context;
const fpu = @import("fpu.zig");
