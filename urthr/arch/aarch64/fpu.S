//! FPU operation is confined to this file since Zig code is compiled without fp_armv8 feature.
//!

// fpuSaveState(state: *anyopaque) -> void
.global fpuSaveState
fpuSaveState:
  stp q0,  q1,  [x0, #( 0*32)]
  stp q2,  q3,  [x0, #( 1*32)]
  stp q4,  q5,  [x0, #( 2*32)]
  stp q6,  q7,  [x0, #( 3*32)]
  stp q8,  q9,  [x0, #( 4*32)]
  stp q10, q11, [x0, #( 5*32)]
  stp q12, q13, [x0, #( 6*32)]
  stp q14, q15, [x0, #( 7*32)]
  stp q16, q17, [x0, #( 8*32)]
  stp q18, q19, [x0, #( 9*32)]
  stp q20, q21, [x0, #(10*32)]
  stp q22, q23, [x0, #(11*32)]
  stp q24, q25, [x0, #(12*32)]
  stp q26, q27, [x0, #(13*32)]
  stp q28, q29, [x0, #(14*32)]
  stp q30, q31, [x0, #(15*32)]
  mrs x9,  fpsr
  mrs x10, fpcr
  str w9,  [x0, #(16*32+0)]
  str w10, [x0, #(16*32+4)]
  ret

// fpuRestoreState(state: *anyopaque) -> void
.global fpuRestoreState
fpuRestoreState:
  ldp q0,  q1,  [x0, #( 0*32)]
  ldp q2,  q3,  [x0, #( 1*32)]
  ldp q4,  q5,  [x0, #( 2*32)]
  ldp q6,  q7,  [x0, #( 3*32)]
  ldp q8,  q9,  [x0, #( 4*32)]
  ldp q10, q11, [x0, #( 5*32)]
  ldp q12, q13, [x0, #( 6*32)]
  ldp q14, q15, [x0, #( 7*32)]
  ldp q16, q17, [x0, #( 8*32)]
  ldp q18, q19, [x0, #( 9*32)]
  ldp q20, q21, [x0, #(10*32)]
  ldp q22, q23, [x0, #(11*32)]
  ldp q24, q25, [x0, #(12*32)]
  ldp q26, q27, [x0, #(13*32)]
  ldp q28, q29, [x0, #(14*32)]
  ldp q30, q31, [x0, #(15*32)]
  ldr w9,  [x0, #(16*32+0)]
  ldr w10, [x0, #(16*32+4)]
  msr fpsr, x9
  msr fpcr, x10
  ret
