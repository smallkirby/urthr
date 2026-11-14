//! RISC-V trap vector.

#include <constants.autogen.h>

// Context frame size in bytes.
.equ TRAP_FRAME_SIZE, 8 * (31 + 4 + 1)

.macro SAVE_CSR scratch, csr, offset
  csrr \scratch, \csr
  sd   \scratch, \offset(sp)
.endmacro

.macro RESTORE_CSR scratch, csr, offset
  ld   \scratch,  \offset(sp)
  csrw \csr,      \scratch
.endmacro

.section  .text
.balign   0x4
// Direct mode trap vector.
.global   trap_vector
trap_vector:
  addi sp,  sp, -TRAP_FRAME_SIZE
  // Save GPRs.
  sd   ra,   0*8(sp)
  sd   t0,   4*8(sp)
  addi t0,   sp, TRAP_FRAME_SIZE
  sd   t0,   1*8(sp)
  sd   gp,   2*8(sp)
  sd   tp,   3*8(sp)
  sd   t1,   5*8(sp)
  sd   t2,   6*8(sp)
  sd   t3,   7*8(sp)
  sd   t4,   8*8(sp)
  sd   t5,   9*8(sp)
  sd   t6,  10*8(sp)
  sd   s0,  11*8(sp)
  sd   s1,  12*8(sp)
  sd   s2,  13*8(sp)
  sd   s3,  14*8(sp)
  sd   s4,  15*8(sp)
  sd   s5,  16*8(sp)
  sd   s6,  17*8(sp)
  sd   s7,  18*8(sp)
  sd   s8,  19*8(sp)
  sd   s9,  20*8(sp)
  sd   s10, 21*8(sp)
  sd   s11, 22*8(sp)
  sd   a0,  23*8(sp)
  sd   a1,  24*8(sp)
  sd   a2,  25*8(sp)
  sd   a3,  26*8(sp)
  sd   a4,  27*8(sp)
  sd   a5,  28*8(sp)
  sd   a6,  29*8(sp)
  sd   a7,  30*8(sp)
  // Save CSRs.
  SAVE_CSR t0, sepc,    31*8
  SAVE_CSR t0, sstatus, 32*8
  SAVE_CSR t0, scause,  33*8
  SAVE_CSR t0, stval,   34*8

  // Call the handler.
  mv   a0, sp
  call handleTrap

  // Restore CSRs.
  RESTORE_CSR t0, sepc,     31*8
  RESTORE_CSR t0, sstatus,  32*8
  // Restore GPRs.
  ld   ra,   0*8(sp)
  ld   gp,   2*8(sp)
  ld   tp,   3*8(sp)
  ld   t0,   4*8(sp)
  ld   t1,   5*8(sp)
  ld   t2,   6*8(sp)
  ld   t3,   7*8(sp)
  ld   t4,   8*8(sp)
  ld   t5,   9*8(sp)
  ld   t6,  10*8(sp)
  ld   s0,  11*8(sp)
  ld   s1,  12*8(sp)
  ld   s2,  13*8(sp)
  ld   s3,  14*8(sp)
  ld   s4,  15*8(sp)
  ld   s5,  16*8(sp)
  ld   s6,  17*8(sp)
  ld   s7,  18*8(sp)
  ld   s8,  19*8(sp)
  ld   s9,  20*8(sp)
  ld   s10, 21*8(sp)
  ld   s11, 22*8(sp)
  ld   a0,  23*8(sp)
  ld   a1,  24*8(sp)
  ld   a2,  25*8(sp)
  ld   a3,  26*8(sp)
  ld   a4,  27*8(sp)
  ld   a5,  28*8(sp)
  ld   a6,  29*8(sp)
  ld   a7,  30*8(sp)
  addi sp, sp, TRAP_FRAME_SIZE

  sret
