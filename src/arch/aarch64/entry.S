.section .text.boot

.global _start

_start:
  // Check affinity.
  mrs   x0, MPIDR_EL1
  and   x0, x0, #0xFF
  ldr   x1, =0
  cmp   x0, x1
  b.ne  .Lhang

  // Clear BSS.
  ldr   x0, =__bss_start
  ldr   x1, =__bss_end
.Lbss_loop:
  cmp   x0, x1
  b.eq  .Ljump_init
  stp   xzr, xzr, [x0], #16
  b     .Lbss_loop

.Ljump_init:
  // Setup stack pointer.
  ldr   x0, =_boot_stack
  mov   sp, x0

  // Jump to kernel init.
  b     kinit

.Lhang:
  wfe
  b    .Lhang
