//! Context switch implementation for AArch64.

// switchContextAsm(oldsp: *usize, newsp: *const usize, prev: *anyopaque) -> *anyopaque
.global switchContextAsm
switchContextAsm:
  // Save callee-saved registers to current stack.
  stp x19, x20, [sp, #-16]!
  stp x21, x22, [sp, #-16]!
  stp x23, x24, [sp, #-16]!
  stp x25, x26, [sp, #-16]!
  stp x27, x28, [sp, #-16]!
  stp x29, x30, [sp, #-16]!

  // Save current SP.
  mov x4, sp
  str x4, [x0]

  // Switch to new SP.
  ldr x4, [x1]
  mov sp, x4

  // Restore callee-saved registers from new stack.
  ldp x29, x30, [sp], #16
  ldp x27, x28, [sp], #16
  ldp x25, x26, [sp], #16
  ldp x23, x24, [sp], #16
  ldp x21, x22, [sp], #16
  ldp x19, x20, [sp], #16

  // Return the previous thread pointer.
  mov x0, x2

  ret
