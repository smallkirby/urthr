//! Aarch64 secondary cores boot code.

.section .text.boot

.global _substart

_substart:
  dsb sy
  isb

.Ljump_el1:
  mrs  x0, CurrentEL
  cmp  x0, #(2 << 2)      // Check if we are at EL2.
  b.ne .Lprepare_el1

  // Prepare to jump to EL1.

  mov   x0, #(1 << 31)      // Set EL1 to use AArch64.
  msr   HCR_EL2, x0

  mrs   x0, CNTHCTL_EL2
  orr   x0, x0, #(0b11 << 0) // Enable EL1 access to timers.
  msr   CNTHCTL_EL2, x0

  mov   x0, #(0b0101 << 0)  // EL1h
  msr   SPSR_EL2, x0

  // Set EL1 stack pointer.
  adr   x0, 0
  msr   SP_EL1, x0
  // Set return address to el1_entry.
  adr   x0, .Lel1_entry
  msr   ELR_EL2, x0

  eret

.Lprepare_el1:

.Lel1_entry:
  // Calculate VA-PA offset.
  adr  x10, 1f
  ldr  x11, =1f
1:
  sub  x11, x11, x10 // VA - PA offset

  // Compute physical address of the boot data.
  ldr  x10, =_boot_data
  sub  x10, x10, x11

  // Load the boot data.
  ldr   x0, [x10, #0]   // TTBR0_EL1
  ldr   x1, [x10, #8]   // TTBR1_EL1
  ldr   x2, [x10, #16]  // TCR_EL1
  ldr   x3, [x10, #24]  // MAIR_EL1
  ldr   x4, [x10, #32]  // Entry
  ldr   x5, [x10, #40]  // Stack

  // Configure MMU.
  msr   TTBR0_EL1 , x0
  msr   TTBR1_EL1 , x1
  msr   TCR_EL1   , x2
  msr   MAIR_EL1  , x3

  // Enable MMU.
  isb
  dsb   sy
  tlbi  vmalle1
  dsb   sy
  isb
  mrs   x0, SCTLR_EL1
  orr   x0, x0, #(1 << 0)   // MMU enable
  orr   x0, x0, #(1 << 2)   // Data cache enable
  orr   x0, x0, #(1 << 12)  // Instruction cache enable
  msr   SCTLR_EL1, x0
  isb

  // Jump to the kernel subcore entry point.
  mov   sp, x5
  mov   x0, x4
  br    x0

.Lhang:
  wfe
  b    .Lhang
