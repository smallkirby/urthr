.section .text

.global __uaccess_copy_faultable_begin
.global __uaccess_copy_faultable_end

.balign 16
__uaccess_copy_faultable_begin:

// __uaccess_copy(dst: [*]u8, src: [*]const u8, len: usize) usize
.global __uaccess_copy
__uaccess_copy:
  movq %rdx, %rcx
  cld
  rep movsb
  xorq %rax, %rax
  retq

__uaccess_copy_faultable_end:

.global __uaccess_copy_fixup
__uaccess_copy_fixup:
  movq %rcx, %rax
  retq
