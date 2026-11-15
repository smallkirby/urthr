//! FPU operation is confined to this file since Zig code is compiled without D extension.
//!

#include "trap.inc.S"

// Assumes D extension is available.
.option arch, +d

/// Enable FP access in S-mode.
///
/// Clobbers \tmp.
/// \old receives the previous SSTATUS.FS bits.
.macro FPU_ENABLE old, tmp
  li   \tmp, SSTATUS_FS
  csrr \old, sstatus
  and  \old, \old, \tmp
  csrs sstatus, \tmp
.endmacro

/// Restore SSTATUS.FS bits from \old.
///
/// Clobbers \tmp.
.macro FPU_RESTORE_FS old, tmp
  li   \tmp, SSTATUS_FS
  csrc sstatus, \tmp
  csrs sstatus, \old
.endmacro

.section  .text

/// fpuSaveState(state: *anyopaque) -> void
.global fpuSaveState
fpuSaveState:
  FPU_ENABLE t0, t1
  fsd  f0,   0*8(a0)
  fsd  f1,   1*8(a0)
  fsd  f2,   2*8(a0)
  fsd  f3,   3*8(a0)
  fsd  f4,   4*8(a0)
  fsd  f5,   5*8(a0)
  fsd  f6,   6*8(a0)
  fsd  f7,   7*8(a0)
  fsd  f8,   8*8(a0)
  fsd  f9,   9*8(a0)
  fsd  f10, 10*8(a0)
  fsd  f11, 11*8(a0)
  fsd  f12, 12*8(a0)
  fsd  f13, 13*8(a0)
  fsd  f14, 14*8(a0)
  fsd  f15, 15*8(a0)
  fsd  f16, 16*8(a0)
  fsd  f17, 17*8(a0)
  fsd  f18, 18*8(a0)
  fsd  f19, 19*8(a0)
  fsd  f20, 20*8(a0)
  fsd  f21, 21*8(a0)
  fsd  f22, 22*8(a0)
  fsd  f23, 23*8(a0)
  fsd  f24, 24*8(a0)
  fsd  f25, 25*8(a0)
  fsd  f26, 26*8(a0)
  fsd  f27, 27*8(a0)
  fsd  f28, 28*8(a0)
  fsd  f29, 29*8(a0)
  fsd  f30, 30*8(a0)
  fsd  f31, 31*8(a0)
  frcsr t2
  sd   t2,  32*8(a0)
  FPU_RESTORE_FS t0, t1
  ret

// fpuRestoreState(state: *anyopaque) -> void
.global fpuRestoreState
fpuRestoreState:
  FPU_ENABLE t0, t1
  fld  f0,   0*8(a0)
  fld  f1,   1*8(a0)
  fld  f2,   2*8(a0)
  fld  f3,   3*8(a0)
  fld  f4,   4*8(a0)
  fld  f5,   5*8(a0)
  fld  f6,   6*8(a0)
  fld  f7,   7*8(a0)
  fld  f8,   8*8(a0)
  fld  f9,   9*8(a0)
  fld  f10, 10*8(a0)
  fld  f11, 11*8(a0)
  fld  f12, 12*8(a0)
  fld  f13, 13*8(a0)
  fld  f14, 14*8(a0)
  fld  f15, 15*8(a0)
  fld  f16, 16*8(a0)
  fld  f17, 17*8(a0)
  fld  f18, 18*8(a0)
  fld  f19, 19*8(a0)
  fld  f20, 20*8(a0)
  fld  f21, 21*8(a0)
  fld  f22, 22*8(a0)
  fld  f23, 23*8(a0)
  fld  f24, 24*8(a0)
  fld  f25, 25*8(a0)
  fld  f26, 26*8(a0)
  fld  f27, 27*8(a0)
  fld  f28, 28*8(a0)
  fld  f29, 29*8(a0)
  fld  f30, 30*8(a0)
  fld  f31, 31*8(a0)
  ld   t2,  32*8(a0)
  fscsr t2
  FPU_RESTORE_FS t0, t1
  ret
