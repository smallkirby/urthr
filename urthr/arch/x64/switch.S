// switchContextAsm(oldsp: *usize, newsp: *const usize, prev: *anyopaque) -> *anyopaque
.global switchContextAsm
switchContextAsm:
  // Save callee-saved registers to current stack.
  pushq %rbp
  pushq %rbx
  pushq %r12
  pushq %r13
  pushq %r14
  pushq %r15

  // Save FSBASE.
  rdfsbase  %rax
  pushq     %rax

  // Save current RSP.
  movq %rsp, (%rdi)

  // Switch to new RSP.
  movq (%rsi), %rsp

  // Restore FSBASE.
  popq      %rax
  wrfsbase  %rax

  // Restore callee-saved registers from new stack.
  popq %r15
  popq %r14
  popq %r13
  popq %r12
  popq %rbx
  popq %rbp

  // Return the previous thread pointer.
  movq %rdx, %rax

  ret
