// Aarch64 boot code.
//
// Shared between bootloader and kernel.

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
  b.eq  .Ljump_el1
  stp   xzr, xzr, [x0], #16
  b     .Lbss_loop

.Ljump_el1:
  mrs  x0, CurrentEL
  cmp  x0, #(2 << 2)      // Check if we are at EL2.
  b.ne .Lprepare_el1

  // If she's in EL2, she is a bootloader.
  // Prepare to jump to EL1.

  mov   x0, #(1 << 31)      // Set EL1 to use AArch64.
  msr   HCR_EL2, x0

  mrs   x0, CNTHCTL_EL2
  orr   x0, x0, #(0b11 << 0) // Enable EL1 access to timers.
  msr   CNTHCTL_EL2, x0

  mov   x0, #(0b0101 << 0)  // EL1h
  msr   SPSR_EL2, x0

  // Set EL1 stack pointer.
  ldr   x0, =_boot_stack
  msr   SP_EL1, x0
  // Set return address to el1_entry.
  ldr   x0, =.Lel1_entry
  msr   ELR_EL2, x0

  eret

.Lprepare_el1:
  // If she's in EL1, she is a kernel.
  ldr  x0, =_boot_stack
  mov  sp, x0

.Lel1_entry:
.Ljump_to_kernel:
  // Jump to the bootloader or kernel entry point.
  ldr   x0, =kmain
  br    x0

.Lhang:
  wfe
  b    .Lhang
