// SSTATUS.SUM: Permit Supervisor User Memory access.
#define SSTATUS_SUM (1 << 18)

.section .text

.global __uaccess_copy_faultable_begin
.global __uaccess_copy_faultable_end

// __uaccess_copy(dst: [*]u8, src: [*]const u8, len: usize) usize
.balign 4
__uaccess_copy_faultable_begin:
.global __uaccess_copy
__uaccess_copy:
  // Allow access to user-space memory.
  li    t0, SSTATUS_SUM
  csrs  sstatus, t0

1:
  // Copy memory byte by byte.
  beqz  a2, 2f
  lbu   t1, 0(a1)
  sb    t1, 0(a0)
  addi  a1, a1, 1
  addi  a0, a0, 1
  addi  a2, a2, -1
  j     1b
2:
  // Disallow access to user-space memory.
  csrc  sstatus, t0

  li    a0, 0
  ret

__uaccess_copy_faultable_end:

.global __uaccess_copy_fixup
__uaccess_copy_fixup:
  // Disallow access to user-space memory.
  li    t0, SSTATUS_SUM
  csrc  sstatus, t0
  // Return the remaining byte count.
  mv    a0, a2
  ret
