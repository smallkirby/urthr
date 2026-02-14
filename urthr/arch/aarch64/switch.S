//! Context switch implementation for AArch64.

// switchContext(old: *usize, new: *const usize)
.global switchContext
switchContext:
  // Save callee-saved registers to current stack.
  stp x19, x20, [sp, #-16]!
  stp x21, x22, [sp, #-16]!
  stp x23, x24, [sp, #-16]!
  stp x25, x26, [sp, #-16]!
  stp x27, x28, [sp, #-16]!
  stp x29, x30, [sp, #-16]!

  // Save current SP.
  mov x2, sp
  str x2, [x0]

  // Switch to new SP.
  ldr x2, [x1]
  mov sp, x2

  // Restore callee-saved registers from new stack.
  ldp x29, x30, [sp], #16
  ldp x27, x28, [sp], #16
  ldp x25, x26, [sp], #16
  ldp x23, x24, [sp], #16
  ldp x21, x22, [sp], #16
  ldp x19, x20, [sp], #16

  ret
