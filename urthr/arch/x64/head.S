# x64 boot code for Urthr kernel.

.section .text.boot

.global _start

_start:
  # Clear BSS.
  cld
  lea   __bss_start(%rip), %rdi
  lea   __bss_end(%rip), %rcx
  sub   %rdi, %rcx
  shr   $3, %rcx
  xor   %rax, %rax
  rep   stosq

  # Set stack pointer.
  lea   _boot_stack(%rip), %rsp

  # Jump to kernel entry point.
  lea   kmain(%rip), %rax
  call  *%rax

.Lhang:
  hlt
  jmp   .Lhang
