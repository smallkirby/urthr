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
  b.hs  .Ljump_el1
  stp   xzr, xzr, [x0], #16
  b     .Lbss_loop

.Ljump_el1:
  mrs  x0, CurrentEL
  cmp  x0, #(2 << 2)      // Check if we are at EL2.
  b.ne .Lprepare_el1

  // If she's in EL2, she is a bootloader.
  // Prepare to jump to EL1.

  ldr   x0, =boottime_exception_handlers // Set boot-time exception handlers.
  msr   VBAR_EL2, x0
  msr   VBAR_EL1, x0

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

  isb
  eret

.Lprepare_el1:
  // If she's in EL1, she is a kernel.
  ldr  x0, =_boot_stack
  mov  sp, x0

.Lel1_entry:
.Ljump_to_kernel:
  // Set boot-time exception handlers.
  ldr   x0, =boottime_exception_handlers
  msr   VBAR_EL1, x0

  // Jump to the bootloader or kernel entry point.
  ldr   x0, =kmain
  br    x0

.Lhang:
  wfe
  b    .Lhang

// Boot-time exception handlers.
.balign 0x800
boottime_exception_handlers:
1: // Sync current EL SP0
  b 1b
.balign 0x80
2: // IRQ current EL SP0
  b 2b
.balign 0x80
3: // FIQ current EL SP0
  b 3b
.balign 0x80
4: // SError current EL SP0
  b 4b
.balign 0x80
5: // Sync current EL SPx
  b 5b
.balign 0x80
6: // IRQ current EL SPx
  b 6b
.balign 0x80
7: // FIQ current EL SPx
  b 7b
.balign 0x80
8: // SError current EL SPx
  b 8b
9: // Sync lower EL using AArch64
  b 9b
.balign 0x80
10: // IRQ lower EL using AArch64
  b 10b
.balign 0x80
11: // FIQ lower EL using AArch64
  b 11b
.balign 0x80
12: // SError lower EL using AArch64
  b 12b
13: // Sync lower EL using AArch32
  b 13b
.balign 0x80
14: // IRQ lower EL using AArch32
  b 14b
.balign 0x80
15: // FIQ lower EL using AArch32
  b 15b
.balign 0x80
16: // SError lower EL using AArch32
  b 16b
