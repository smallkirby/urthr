.section  .text

// enterUserland(pc: usize, sp: usize, kstack: usize) noreturn
.global   enterUserland
enterUserland:
  // Reset RSP to the bottom of the kernel stack.
  movq %rdx, %rsp

  // Reload user data segment selectors.
  movw $0x2B, %ax // user DS | RPL-3
  movw %ax,   %ds
  movw %ax,   %es

  // Build the IRETQ frame for a transition to Ring-3.
  pushq $0x2B    // SS: user DS | RPL 3
  pushq %rsi     // RSP: user stack pointer
  pushq $0x202   // RFLAGS: reserved bit1 set, IF set
  pushq $0x33    // CS: user CS | RPL 3
  pushq %rdi     // RIP: user entry point

  // Zero out all general-purpose registers before entering userland.
  xorq %rax, %rax
  xorq %rbx, %rbx
  xorq %rcx, %rcx
  xorq %rdx, %rdx
  xorq %rsi, %rsi
  xorq %rdi, %rdi
  xorq %rbp, %rbp
  xorq %r8,  %r8
  xorq %r9,  %r9
  xorq %r10, %r10
  xorq %r11, %r11
  xorq %r12, %r12
  xorq %r13, %r13
  xorq %r14, %r14
  xorq %r15, %r15

  // Drop to Ring-3.
  iretq
