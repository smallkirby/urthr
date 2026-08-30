.section .text

.global __uaccess_copy_faultable_begin
.global __uaccess_copy_faultable_end

// __uaccess_copy(dst: [*]u8, src: [*]const u8, len: usize) usize
.balign 4
__uaccess_copy_faultable_begin:
.global __uaccess_copy
__uaccess_copy:
1:
  cbz   x2, 2f
  ldrb  w3, [x1], #1
  strb  w3, [x0], #1
  sub   x2, x2, #1
  b 1b
2:
  mov   x0, #0
  ret

__uaccess_copy_faultable_end:

.global __uaccess_copy_fixup
__uaccess_copy_fixup:
  mov   x0, x2
  ret
