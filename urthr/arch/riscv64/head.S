// RISC-V boot code.
//
// Entered in S-mode with MMU disabled:
//   a0: Hart ID
//   a1: Physical address of DTB

#include <constants.autogen.h>

// PTE for leaf entries: DAXWRV
#define PTE_LEAF_RWX  0xCF
// PTE for table entries: V
#define PTE_TABLE     0x01
// SATP CSR mode for Sv48.
#define SATP_SV48     9

.section .text.boot

.global _start

_start:
  // Disable and clear interrupts.
  csrci sstatus, 0x2
  csrw  sie, zero
  csrw  sip, zero

  // Save boot parameters.
  mv    s0, a0
  mv    s1, a1

  // SSCRATCH holds the hart ID only during early boot.
  csrw  sscratch, a0

  // Clear BSS.
  lla   t0, __bss_start
  lla   t1, __bss_end
.Lbss_loop:
  bgeu  t0, t1, .Lboot_pgtbl_setup
  sd    zero, 0(t0)
  addi  t0, t0, 8
  j     .Lbss_loop

  // Identity-map the lowest 8 GiB with 1 GiB pages.
.Lboot_pgtbl_setup:
  lla   t0, boot_pgtbl_lv2_lo
  li    t1, 0
  li    t2, 8
  li    t3, PTE_LEAF_RWX
  li    t5, 0x40000000
  // t0: page table entry address
  // t1: current physical address
  // t2: loop counter
  // t3: page attributes
  // t5: page size
.Lboot_pgtbl_lv2_lo_loop:
  srli  t4, t1, (12 - 10)
  or    t4, t4, t3
  sd    t4, 0(t0)
  addi  t0, t0, 8
  add   t1, t1, t5
  addi  t2, t2, -1
  bnez  t2, .Lboot_pgtbl_lv2_lo_loop

  // Map the kernel image to the kernel virtual address with 2 MiB pages.
  lla   t0, boot_pgtbl_lv1
  lla   t1, _start
  lla   t2, __end
  sub   t2, t2, t1
  li    t3, 0x1FFFFF
  add   t2, t2, t3
  srli  t2, t2, 21
  li    t3, PTE_LEAF_RWX
  li    t5, 0x200000
  // t0: page table entry address
  // t1: current physical address
  // t2: loop counter
  // t3: page attributes
  // t5: page size
.Lboot_pgtbl_lv1_loop:
  srli  t4, t1, 2
  or    t4, t4, t3
  sd    t4, 0(t0)
  addi  t0, t0, 8
  add   t1, t1, t5
  addi  t2, t2, -1
  bnez  t2, .Lboot_pgtbl_lv1_loop

  // lv3[0] -> lv2_lo: ID-map
  lla   t0, boot_pgtbl_lv3
  lla   t1, boot_pgtbl_lv2_lo
  srli  t1, t1, (12 - 10)
  ori   t1, t1, PTE_TABLE
  sd    t1, 0(t0)

  // lv2[510] -> lv2_hi: kernel virtual address
  li    t2, ((V_KERNEL_START >> 39) & 0x1FF) * 8
  add   t2, t2, t0
  lla   t1, boot_pgtbl_lv2_hi
  srli  t1, t1, (12 - 10)
  ori   t1, t1, PTE_TABLE
  sd    t1, 0(t2)

  // lv2_hi[0] -> lv1: kernel image
  lla   t0, boot_pgtbl_lv2_hi
  lla   t1, boot_pgtbl_lv1
  srli  t1, t1, (12 - 10)
  ori   t1, t1, PTE_TABLE
  sd    t1, 0(t0)

  // Enable MMU with no ASID.
  lla   t0, boot_pgtbl_lv3
  srli  t0, t0, 12
  li    t1, SATP_SV48
  slli  t1, t1, 60
  or    t0, t0, t1
  ld    t2, .Lvirt_entry_ptr // stash virtual entry point
  csrw  satp, t0
  sfence.vma zero, zero

  // Check if the paging mode was accepted.
  csrr  t1, satp
  bne   t0, t1, .Lhang

  // Jump to the virtual address.
  jr    t2

.balign 8
.Lvirt_entry_ptr:
  .dword _virt_entry

_virt_entry:
  // Set boot-time stack.
  lla   sp, _boot_stack

  // Set boot-time exception vector.
  lla   t0, boottime_trap
  csrw  stvec, t0

  // Jump to the kernel entry point.
  mv    a0, s1 // DTB
  call  kmain

.Lhang:
  j     .Lhang

// Boot-time trap handler. Just loops indefinitely.
.balign 4
boottime_trap:
  j     boottime_trap

// Boot-time page tables.
.section .bss.boot_pgtbl, "aw", @nobits
.balign 4096
boot_pgtbl_lv3:
  .skip 4096
boot_pgtbl_lv2_lo:
  .skip 4096
boot_pgtbl_lv2_hi:
  .skip 4096
boot_pgtbl_lv1:
  .skip 4096
