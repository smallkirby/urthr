// Secondary harts boot entry point.
//
// Entered in S-mode with MMU disabled by SBI HSM:
//   a0: Hart ID
//   a1: Opaque value
//

.section .text.boot

.balign 4
.global _substart
.global _subend
.global _smp_boot_data

_substart:
  // Disable and clear interrupts.
  csrci sstatus, 0x2
  csrw  sie, zero
  csrw  sip, zero

  // SSCRATCH holds the hart ID only during early boot.
  csrw  sscratch, a0

  // Load the boot data.
  lla   t0, _smp_boot_data
  ld    t1, 0(t0)   // SATP
  ld    t2, 8(t0)   // Entry
  ld    sp, 16(t0)  // Stack

  // Enable MMU.
  csrw  satp, t1
  sfence.vma

  // Check if the SATP value has been accepted.
  csrr  t3, satp
  bne   t1, t3, .Lhang

  // Terminate the frame chain.
  mv    s0, zero
  mv    ra, zero

  // Jump to the kernel subcore entry point.
  jr    t2

.Lhang:
  wfi
  j     .Lhang

// =============================================================
// Boot data

.balign 8
_smp_boot_data:
  .dword 0  // SATP
  .dword 0  // Entry
  .dword 0  // Stack

_subend:
