.section  .text
.global   enterUserland

// enterUserland(pc: usize, sp: usize) noreturn
enterUserland:
  // Set up registers for eret.
  msr elr_el1, x0
  msr sp_el0,  x1
  mov x2, #0
  msr spsr_el1, x2 // EL0, AArch64, all interrupts unmasked
  isb

  // Zero out all general-purpose registers before entering userland.
  mov x0,  xzr
  mov x1,  xzr
  mov x2,  xzr
  mov x3,  xzr
  mov x4,  xzr
  mov x5,  xzr
  mov x6,  xzr
  mov x7,  xzr
  mov x8,  xzr
  mov x9,  xzr
  mov x10, xzr
  mov x11, xzr
  mov x12, xzr
  mov x13, xzr
  mov x14, xzr
  mov x15, xzr
  mov x16, xzr
  mov x17, xzr
  mov x18, xzr
  mov x19, xzr
  mov x20, xzr
  mov x21, xzr
  mov x22, xzr
  mov x23, xzr
  mov x24, xzr
  mov x25, xzr
  mov x26, xzr
  mov x27, xzr
  mov x28, xzr
  mov x29, xzr
  mov x30, xzr

  // Drop to EL0.
  eret
