// switchContextAsm(old: *usize, new: *const usize)
.global switchContextAsm
switchContextAsm:
  // Save callee-saved registers to current stack.
  pushq %rbp
  pushq %rbx
  pushq %r12
  pushq %r13
  pushq %r14
  pushq %r15

  // Save current RSP.
  movq %rsp, (%rdi)

  // Switch to new RSP.
  movq (%rsi), %rsp

  // Restore callee-saved registers from new stack.
  popq %r15
  popq %r14
  popq %r13
  popq %r12
  popq %rbx
  popq %rbp

  ret
