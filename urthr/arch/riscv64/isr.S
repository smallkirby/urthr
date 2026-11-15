//! RISC-V trap vector.

#include <constants.autogen.h>
#include "trap.inc.S"

.section  .text

/// Direct mode trap vector.
///
/// SSCRATCH on entry:
/// - U-mode: pointer to the per-CPU trap scratch area.
/// - S-mode: zero, or the hart ID only during early boot.
.balign 0x4
.global trap_vector
trap_vector:
  // Stash user SP.
  csrrw sp, sscratch, sp
  // If SSCRATCH's MSB is set, it's kernel pointer and indicates a trap from U-mode.
  bltz  sp, .Ltrap_from_user

.Ltrap_from_smode:
  // Undo the swap of SP and SSCRATCH.
  csrrw sp, sscratch, sp

  // Construct a trap frame.
  addi  sp, sp, -TRAP_FRAME_SIZE
  SAVE_GPRS
  // Save T0.
  sd    t0, TRAP_CONTEXT_T0(sp)
  // Save SP.
  addi  t0, sp, TRAP_FRAME_SIZE
  sd    t0, TRAP_CONTEXT_SP(sp)
  // Save TP.
  sd    tp, TRAP_CONTEXT_TP(sp)

  j .Ltrap_common

.Ltrap_from_user:
  // SP       : SSCRATCH area
  // SSCRATCH : user SP

  sd    t0, SCRATCH_T0(sp)
  // Mark that we're in S-mode.
  csrrw t0, sscratch, zero
  // Save user SP.
  sd    t0, SCRATCH_USP(sp)

  // Switch to the kernel stack.
  mv    t0, sp
  ld    sp, SCRATCH_KSP(t0)

  // Construct a trap frame on the kernel stack.
  addi  sp, sp, -TRAP_FRAME_SIZE
  SAVE_GPRS
  // Save T0.
  ld    t1, SCRATCH_T0(t0)
  sd    t1, TRAP_CONTEXT_T0(sp)
  // Save SP.
  ld    t1, SCRATCH_USP(t0)
  sd    t1, TRAP_CONTEXT_SP(sp)
  // Save TP.
  sd    tp, TRAP_CONTEXT_TP(sp)
  // Restore kernel TP.
  ld    tp, SCRATCH_KTP(t0)

.Ltrap_common:
  SAVE_CSR t0, sepc, TRAP_CONTEXT_SEPC
  SAVE_CSR t0, sstatus, TRAP_CONTEXT_SSTATUS
  SAVE_CSR t0, scause, TRAP_CONTEXT_SCAUSE
  SAVE_CSR t0, stval, TRAP_CONTEXT_STVAL

  // Call the handler.
  mv    a0, sp
  call  handleTrap

.global exit_exception
exit_exception:
  // Restore CSRs.
  ld    t0, TRAP_CONTEXT_SEPC(sp)
  csrw  sepc, t0
  ld    t1, TRAP_CONTEXT_SSTATUS(sp)
  csrw  sstatus, t1

  // Check the previous privilege mode.
  andi  t1, t1, SSTATUS_SPP
  bnez  t1, .Lexit_to_kernel

.Lexit_to_user:
  SETUP_USER_SSCRATCH t0
  RESTORE_GPRS
  ld tp, TRAP_CONTEXT_TP(sp)
  ld t0, TRAP_CONTEXT_T0(sp)
  ld sp, TRAP_CONTEXT_SP(sp)
  sret

.Lexit_to_kernel:
  RESTORE_GPRS
  ld   t0, TRAP_CONTEXT_T0(sp)
  addi sp, sp, TRAP_FRAME_SIZE
  sret
