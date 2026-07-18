.section  .text

// enterUserland(pc: usize, sp: usize, kstack: usize) noreturn
.global   enterUserland
enterUserland:
  hlt
