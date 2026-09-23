//! Interrupt service routine stub generator.

/// ISR signature.
pub const Isr = fn () callconv(.naked) void;

/// CPU context saved during an interrupt.
pub const Context = intr.Context;

/// Zig entry point of the interrupt handler.
export fn intrZigEntry(ctx: *Context) callconv(.c) void {
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

    // SS is set to NULL if there's privilege change. Reload kernel DS.
    asm volatile (
        \\mov %[kernel_ds], %%ax
        \\mov %%ax, %%ss
        :
        : [kernel_ds] "n" (@as(u16, @bitCast(gdt.SegSel{
            .rpl = 0,
            .index = .kernel_ds,
          }))),
        : .{ .ax = true });

    // Push the context and call the handler.
    asm volatile (
        \\pushq %%rsp
        \\popq  %%rdi
        // Align stack to 16 bytes.
        \\pushq %%rsp
        \\pushq (%%rsp)
        \\andq  $-0x10, %%rsp

        // Call the dispatcher.
        \\call intrZigEntry

        // Restore the stack.
        \\movq 8(%%rsp), %%rsp

        // Return from ISR context.
        \\jmp isrReturn
    );
}

/// Restore general-purpose registers from a context at the top of the stack,
/// discard the vector and error code, and return from the interrupt.
export fn isrReturn() callconv(.naked) noreturn {
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
const gdt = @import("gdt.zig");
