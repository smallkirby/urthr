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
    am.sti();
    defer am.cli();

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
    exception.callEreturnHook(ctx);
}

/// User RSP scratch at the SYSCALL entry.
export var _scratch_sp: usize linksection(common.pcpu.section) = 0;

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
        \\cli
        // Switch onto the kernel stack.
        \\movq %%rsp, %%gs:_scratch_sp(%%rip)
        \\movq %%gs:ksp_top(%%rip), %%rsp
        \\
        // Build a CPU context as if a normal interrupt had been taken from Ring-3.
        \\pushq %[user_ss]
        \\pushq %%gs:_scratch_sp(%%rip)   // User RSP
        \\pushq %%r11                   // User RFLAGS
        \\pushq %[user_cs]              // User CS
        \\pushq %%rcx                   // User RIP
        \\pushq $0                      // No error code
        \\pushq $0                      // No vector
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
        \\pushq %%r13
        \\pushq %%r14
        \\pushq %%r15
        \\
        // SS is set to NULL if there's privilege change. Reload kernel DS.
        \\mov %[kernel_ds], %%ax
        \\mov %%ax, %%ss
        \\
        \\clac
        \\
        \\movq %%rsp, %%rdi
        \\
        // Dispatch to the Zig SVC handler.
        \\sti
        \\call svc
        \\cli
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
          [kernel_ds] "n" (@as(u16, @bitCast(gdt.SegSel{ .rpl = 0, .index = .kernel_ds }))),
    );
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const am = @import("asm.zig");
const gdt = @import("gdt.zig");
const regs = @import("register.zig");
const exception = @import("exception.zig");
const Context = exception.Context;
