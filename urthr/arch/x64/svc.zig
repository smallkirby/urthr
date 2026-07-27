/// SVC handler function type.
///
/// When null is returned, X0 is not modified and returned as-is to user.
const HandlerFn = fn (
    nr: u64,
    arg1: u64,
    arg2: u64,
    arg3: u64,
    arg4: u64,
    arg5: u64,
    arg6: u64,
) ?i64;

/// SVC dispatcher.
var dispatcher: *const HandlerFn = undefined;

/// Set SVC handler function.
pub fn setHandler(f: *const HandlerFn) void {
    dispatcher = f;
}

/// Enable SYSCALL instruction.
pub fn init() void {
    // Enable SYSCALL and SYSRET.
    var efer = am.rdmsr(.efer);
    efer.sce = true;
    am.wrmsr(.efer, efer);

    // Set up SYSCALL target addresses.
    am.wrmsr(.star, .{
        .syscall_sel = @bitCast(gdt.SegSel{ .rpl = 0, .index = .kernel_cs }),
        .sysret_sel = @bitCast(gdt.SegSel{ .rpl = 0, .index = .user_cs32 }),
    });
    am.wrmsr(.lstar, .{ .addr = @intFromPtr(&syscallEntry) });
    // Set up SYSCALL flags mask.
    am.wrmsr(.fmask, .{
        .mask = @bitCast(std.mem.zeroInit(regs.Rflags, .{
            .tf = true,
            .ie = true,
            .df = true,
        })),
    });
}

/// Zig entry point of the SYSCALL handler.
export fn svc(ctx: *Context) callconv(.c) void {
    const nr = ctx.rax;
    const arg1 = ctx.rdi;
    const arg2 = ctx.rsi;
    const arg3 = ctx.rdx;
    const arg4 = ctx.r10; // Linux syscall ABI
    const arg5 = ctx.r8;
    const arg6 = ctx.r9;

    if (dispatcher(
        nr,
        arg1,
        arg2,
        arg3,
        arg4,
        arg5,
        arg6,
    )) |ret| {
        ctx.rax = @bitCast(ret);
    }

    // Deliver any pending signals before returning to userspace.
    exception.callEreturnHook();
}

/// SYSCALL entry point.
///
/// On entry, interrupts are disabled since IA32_FMASK masks IF bit.
///
/// Register usage:
///   RAX: syscall number
///   RDI: arg1
///   RSI: arg2
///   RDX: arg3
///   R10: arg4
///   R8:  arg5
///   R9:  arg6
///   RSP: user stack pointer
///   R11: RFLAGS
///   RCX: RIP
///   RBX: callee-saved
///   RBP: callee-saved
///   R12: callee-saved
///   R13: callee-saved
///   R14: callee-saved
///   R15: callee-saved
///
/// Therefore, no registers are usable before saving them.
export fn syscallEntry() callconv(.naked) noreturn {
    asm volatile (
        \\
        // Spill a part of callee-saved registers onto the user stack.
        \\pushq %%r13
        \\pushq %%r14
        \\pushq %%r15
        \\
        // Reconstruct the user RSP as it was at SYSCALL entry .
        //   R13: Original usen RSP
        //   R14: Per-CPU variable base -> ksp_top
        //   R15: Link address of ksp_top.
        \\leaq 24(%%rsp), %%r13
        \\rdgsbase %%r14
        \\leaq ksp_top(%%rip), %%r15
        \\addq %%r15, %%r14
        \\movq (%%r14), %%r14
        \\
        // Switch onto the kernel stack.
        \\movq %%r14, %%rsp
        \\
        // Build a CPU context as if a normal interrupt had been taken from Ring-3.
        \\pushq %[user_ss]
        \\pushq %%r13    // User RSP
        \\pushq %%r11    // User RFLAGS
        \\pushq %[user_cs]
        \\pushq %%rcx    // User RIP
        \\pushq $0       // No error code
        \\pushq $0       // No vector
        \\
        \\pushq %%rdi
        \\pushq %%rsi
        \\pushq %%rdx
        \\pushq %%rcx
        \\pushq %%rax
        \\pushq %%r8
        \\pushq %%r9
        \\pushq %%r10
        \\pushq %%r11
        \\pushq %%rbx
        \\pushq %%rbp
        \\pushq %%r12
        \\pushq -8(%%r13)  // Spilled R13
        \\pushq -16(%%r13) // Spilled R14
        \\pushq -24(%%r13) // Spilled R15
        \\
        \\movq %%rsp, %%rdi
        \\
        // Save XMM registers.
        // TODO: use FXSAVE instruction.
        \\subq  $(16*8), %%rsp
        \\movdqu %%xmm0, (%%rsp)
        \\movdqu %%xmm1, 16(%%rsp)
        \\movdqu %%xmm2, 32(%%rsp)
        \\movdqu %%xmm3, 48(%%rsp)
        \\movdqu %%xmm4, 64(%%rsp)
        \\movdqu %%xmm5, 80(%%rsp)
        \\movdqu %%xmm6, 96(%%rsp)
        \\movdqu %%xmm7, 112(%%rsp)
        \\
        // Dispatch to the Zig SVC handler.
        \\call svc
        \\
        // Restore XMM registers.
        // TODO: use FXRSTOR instruction.
        \\movdqu (%%rsp), %%xmm0
        \\movdqu 16(%%rsp),  %%xmm1
        \\movdqu 32(%%rsp),  %%xmm2
        \\movdqu 48(%%rsp),  %%xmm3
        \\movdqu 64(%%rsp),  %%xmm4
        \\movdqu 80(%%rsp),  %%xmm5
        \\movdqu 96(%%rsp),  %%xmm6
        \\movdqu 112(%%rsp), %%xmm7
        \\addq $(16*8), %%rsp
        \\
        // Restore CPU context.
        \\popq %%r15
        \\popq %%r14
        \\popq %%r13
        \\popq %%r12
        \\popq %%rbp
        \\popq %%rbx
        \\popq %%r11
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rax
        \\popq %%rcx
        \\popq %%rdx
        \\popq %%rsi
        \\popq %%rdi
        \\
        // Discard fake ISR context.
        \\addq $0x10, %%rsp // Vector and error code
        \\popq %%rcx        // RIP
        \\addq $8, %%rsp    // CS
        \\popq %%r11        // RFLAGS
        \\popq %%rsp        // RSP
        \\
        // Return to userland.
        \\sysretq
        :
        : [user_ss] "n" (@as(u16, @bitCast(gdt.SegSel{ .rpl = 3, .index = .user_ds }))),
          [user_cs] "n" (@as(u16, @bitCast(gdt.SegSel{ .rpl = 3, .index = .user_cs }))),
    );
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const am = @import("asm.zig");
const gdt = @import("gdt.zig");
const regs = @import("register.zig");
const exception = @import("exception.zig");
const Context = exception.Context;
