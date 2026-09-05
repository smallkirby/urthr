.arch armv8.1-a

.section .text

.global __uaccess_copy_faultable_begin
.global __uaccess_copy_faultable_end

// __uaccess_copy(dst: [*]u8, src: [*]const u8, len: usize) usize
.balign 4
__uaccess_copy_faultable_begin:
.global __uaccess_copy
__uaccess_copy:
  // Check if PAN is usable.
  adrp  x9, pan_usable
  ldrb  w9, [x9, :lo12:pan_usable]
  cbz   w9, 1f
  // Disable PAN.
  msr   PAN, #0
1:
  // Copy memory byte by byte.
  cbz   x2, 2f
  ldrb  w3, [x1], #1
  strb  w3, [x0], #1
  sub   x2, x2, #1
  b 1b
2:
  cbz   w9, 3f
  // Re-enable PAN.
  msr   PAN, #1
3:
  mov   x0, #0
  ret

__uaccess_copy_faultable_end:

.global __uaccess_copy_fixup
__uaccess_copy_fixup:
  // Re-enable PAN.
  adrp  x9, pan_usable
  ldrb  w9, [x9, :lo12:pan_usable]
  cbz   w9, 1f
  msr   PAN, #1
1:
  mov   x0, x2
  ret
