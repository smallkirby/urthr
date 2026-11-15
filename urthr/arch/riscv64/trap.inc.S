/// Context frame size in bytes.
///
/// 31 GPRs, 4 saved CSRs, and 1 padding field.
.equ TRAP_FRAME_SIZE, 8 * (31 + 4 + 1)

/// Offsets in bytes of the fields in the trap context.
.equ TRAP_CONTEXT_RA,       0 * 8
.equ TRAP_CONTEXT_SP,       1 * 8
.equ TRAP_CONTEXT_GP,       2 * 8
.equ TRAP_CONTEXT_TP,       3 * 8
.equ TRAP_CONTEXT_T0,       4 * 8
.equ TRAP_CONTEXT_T1,       5 * 8
.equ TRAP_CONTEXT_T2,       6 * 8
.equ TRAP_CONTEXT_T3,       7 * 8
.equ TRAP_CONTEXT_T4,       8 * 8
.equ TRAP_CONTEXT_T5,       9 * 8
.equ TRAP_CONTEXT_T6,      10 * 8
.equ TRAP_CONTEXT_S0,      11 * 8
.equ TRAP_CONTEXT_S1,      12 * 8
.equ TRAP_CONTEXT_S2,      13 * 8
.equ TRAP_CONTEXT_S3,      14 * 8
.equ TRAP_CONTEXT_S4,      15 * 8
.equ TRAP_CONTEXT_S5,      16 * 8
.equ TRAP_CONTEXT_S6,      17 * 8
.equ TRAP_CONTEXT_S7,      18 * 8
.equ TRAP_CONTEXT_S8,      19 * 8
.equ TRAP_CONTEXT_S9,      20 * 8
.equ TRAP_CONTEXT_S10,     21 * 8
.equ TRAP_CONTEXT_S11,     22 * 8
.equ TRAP_CONTEXT_A0,      23 * 8
.equ TRAP_CONTEXT_A1,      24 * 8
.equ TRAP_CONTEXT_A2,      25 * 8
.equ TRAP_CONTEXT_A3,      26 * 8
.equ TRAP_CONTEXT_A4,      27 * 8
.equ TRAP_CONTEXT_A5,      28 * 8
.equ TRAP_CONTEXT_A6,      29 * 8
.equ TRAP_CONTEXT_A7,      30 * 8
.equ TRAP_CONTEXT_SEPC,    31 * 8
.equ TRAP_CONTEXT_SSTATUS, 32 * 8
.equ TRAP_CONTEXT_SCAUSE,  33 * 8
.equ TRAP_CONTEXT_STVAL,   34 * 8

/// Layout of the per-CPU trap scratch area.
.equ SCRATCH_T0,  0 * 8
.equ SCRATCH_USP, 1 * 8
.equ SCRATCH_KSP, 2 * 8
.equ SCRATCH_KTP, 3 * 8

/// SSTATUS bits layout.
.equ SSTATUS_SIE,   1 << 1
.equ SSTATUS_SPIE,  1 << 5
.equ SSTATUS_UBE,   1 << 6
.equ SSTATUS_SPP,   1 << 8
.equ SSTATUS_VS,    3 << 9
.equ SSTATUS_FS,    3 << 13
.equ SSTATUS_XS,    3 << 15
.equ SSTATUS_SUM,   1 << 18
.equ SSTATUS_MXR,   1 << 19
.equ SSTATUS_SPELP, 1 << 23
.equ SSTATUS_SDT,   1 << 24
.equ SSTATUS_UXL,   3 << 32
.equ SSTATUS_SD,    1 << 63

/// Save the CSR \csr into the stack at the given offset.
///
/// Clobbers \scratch.
.macro SAVE_CSR scratch, csr, offset
  csrr \scratch, \csr
  sd   \scratch, \offset(sp)
.endmacro

/// Save GPRs except for SP, TP, and T0.
///
/// Expects SP to point to the top of the trap frame.
.macro SAVE_GPRS
  sd   ra,  TRAP_CONTEXT_RA(sp)
  sd   gp,  TRAP_CONTEXT_GP(sp)
  sd   t1,  TRAP_CONTEXT_T1(sp)
  sd   t2,  TRAP_CONTEXT_T2(sp)
  sd   t3,  TRAP_CONTEXT_T3(sp)
  sd   t4,  TRAP_CONTEXT_T4(sp)
  sd   t5,  TRAP_CONTEXT_T5(sp)
  sd   t6,  TRAP_CONTEXT_T6(sp)
  sd   s0,  TRAP_CONTEXT_S0(sp)
  sd   s1,  TRAP_CONTEXT_S1(sp)
  sd   s2,  TRAP_CONTEXT_S2(sp)
  sd   s3,  TRAP_CONTEXT_S3(sp)
  sd   s4,  TRAP_CONTEXT_S4(sp)
  sd   s5,  TRAP_CONTEXT_S5(sp)
  sd   s6,  TRAP_CONTEXT_S6(sp)
  sd   s7,  TRAP_CONTEXT_S7(sp)
  sd   s8,  TRAP_CONTEXT_S8(sp)
  sd   s9,  TRAP_CONTEXT_S9(sp)
  sd   s10, TRAP_CONTEXT_S10(sp)
  sd   s11, TRAP_CONTEXT_S11(sp)
  sd   a0,  TRAP_CONTEXT_A0(sp)
  sd   a1,  TRAP_CONTEXT_A1(sp)
  sd   a2,  TRAP_CONTEXT_A2(sp)
  sd   a3,  TRAP_CONTEXT_A3(sp)
  sd   a4,  TRAP_CONTEXT_A4(sp)
  sd   a5,  TRAP_CONTEXT_A5(sp)
  sd   a6,  TRAP_CONTEXT_A6(sp)
  sd   a7,  TRAP_CONTEXT_A7(sp)
.endmacro

/// Restore GPRs except for SP, TP, and T0.
///
/// Expects SP to point to the top of the trap frame.
.macro RESTORE_GPRS
  ld   ra,  TRAP_CONTEXT_RA(sp)
  ld   gp,  TRAP_CONTEXT_GP(sp)
  ld   t1,  TRAP_CONTEXT_T1(sp)
  ld   t2,  TRAP_CONTEXT_T2(sp)
  ld   t3,  TRAP_CONTEXT_T3(sp)
  ld   t4,  TRAP_CONTEXT_T4(sp)
  ld   t5,  TRAP_CONTEXT_T5(sp)
  ld   t6,  TRAP_CONTEXT_T6(sp)
  ld   s0,  TRAP_CONTEXT_S0(sp)
  ld   s1,  TRAP_CONTEXT_S1(sp)
  ld   s2,  TRAP_CONTEXT_S2(sp)
  ld   s3,  TRAP_CONTEXT_S3(sp)
  ld   s4,  TRAP_CONTEXT_S4(sp)
  ld   s5,  TRAP_CONTEXT_S5(sp)
  ld   s6,  TRAP_CONTEXT_S6(sp)
  ld   s7,  TRAP_CONTEXT_S7(sp)
  ld   s8,  TRAP_CONTEXT_S8(sp)
  ld   s9,  TRAP_CONTEXT_S9(sp)
  ld   s10, TRAP_CONTEXT_S10(sp)
  ld   s11, TRAP_CONTEXT_S11(sp)
  ld   a0,  TRAP_CONTEXT_A0(sp)
  ld   a1,  TRAP_CONTEXT_A1(sp)
  ld   a2,  TRAP_CONTEXT_A2(sp)
  ld   a3,  TRAP_CONTEXT_A3(sp)
  ld   a4,  TRAP_CONTEXT_A4(sp)
  ld   a5,  TRAP_CONTEXT_A5(sp)
  ld   a6,  TRAP_CONTEXT_A6(sp)
  ld   a7,  TRAP_CONTEXT_A7(sp)
.endmacro

// Prepare SSCRATCH for U-mode.
//
// Expects TP to be the kernel TP.
// Clobbers \tmp.
.macro SETUP_USER_SSCRATCH tmp
  la   \tmp, trap_scratch
  add  \tmp, \tmp, tp
  sd   tp,   SCRATCH_KTP(\tmp)
  csrw sscratch, \tmp
.endmacro
