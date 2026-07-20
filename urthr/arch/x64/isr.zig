//! Interrupt service routine stub generator.

/// ISR signature.
pub const Isr = fn () callconv(.naked) void;

/// Zig entry point of the interrupt handler.
export fn intrZigEntry(ctx: *CpuContext) callconv(.c) void {
    intr.dispatch(ctx);
}

/// Generate ISR stub for the given vector.
pub fn generateIsr(comptime vector: usize) Isr {
    return struct {
        fn handler() callconv(.naked) void {
            // Clear the interrupt flag.
            asm volatile (
                \\cli
            );

            // If the interrupt does not provide an error code, push a dummy one.
            if (vector != 8 and !(vector >= 10 and vector <= 14) and vector != 17) {
                asm volatile (
                    \\pushq $0
                );
            }

            // Push the vector.
            asm volatile (
                \\pushq %[vector]
                :
                : [vector] "n" (vector),
            );
            // Jump to the common ISR.
            asm volatile (
                \\jmp isrCommon
            );
        }
    }.handler;
}

/// Common stub for all ISR.
///
/// This function assumes that `Context` is saved at the top of the stack except for general-purpose registers.
export fn isrCommon() callconv(.naked) void {
    // Save the general-purpose registers.
    asm volatile (
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
    );

    // Push the context and call the handler.
    asm volatile (
        \\pushq %%rsp
        \\popq  %%rdi
        // Align stack to 16 bytes.
        \\pushq %%rsp
        \\pushq (%%rsp)
        \\andq  $-0x10, %%rsp

        // Save XMM registers
        // TODO: use FXSAVE instruction.
        \\subq $(16*8), %%rsp
        \\movdqu %%xmm0, (%%rsp)
        \\movdqu %%xmm1, 16(%%rsp)
        \\movdqu %%xmm2, 32(%%rsp)
        \\movdqu %%xmm3, 48(%%rsp)
        \\movdqu %%xmm4, 64(%%rsp)
        \\movdqu %%xmm5, 80(%%rsp)
        \\movdqu %%xmm6, 96(%%rsp)
        \\movdqu %%xmm7, 112(%%rsp)

        // Call the dispatcher.
        \\call intrZigEntry

        // Resoter XMM registers
        // TODO: use FXRSTOR instruction.
        \\movdqu (%%rsp), %%xmm0
        \\movdqu 16(%%rsp), %%xmm1
        \\movdqu 32(%%rsp), %%xmm2
        \\movdqu 48(%%rsp), %%xmm3
        \\movdqu 64(%%rsp), %%xmm4
        \\movdqu 80(%%rsp), %%xmm5
        \\movdqu 96(%%rsp), %%xmm6
        \\movdqu 112(%%rsp), %%xmm7
        \\addq $(16*8), %%rsp

        // Restore the stack.
        \\movq 8(%%rsp), %%rsp
    );

    // Restore general-purpose registers, error code, and vector from the stack.
    asm volatile (
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
        \\addq $0x10, %%rsp
        \\iretq
    );
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");

const intr = @import("exception.zig");
const CpuContext = intr.Context;
