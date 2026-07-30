# Secondary core boot entry point.
#
# Cores start in real mode, at a physical address chosen dynamically at boot (< 1MiB).

.set RELOCATE,  0
.set FILL,      0

.set BOOTDATA_CR3,    0x00
.set BOOTDATA_STACK,  0x08
.set BOOTDATA_ENTRY,  0x10

.set MSR_EFER,  0xC0000080
.set EFER_LME,  0x00000100
.set EFER_NXE,  0x00000800
.set CR0_PE,    0x00000001
.set CR0_PG,    0x80000000
.set CR4_PAE,   0x00000020

.set SEG_CODE32,  0x10
.set SEG_DATA32,  0x08
.set SEG_CODE64,  0x20
.set SEG_DATA64,  0x18

#define OFFSET(label) ((label) - _substart)

# =============================================================

.section .text.boot

.global _substart
.global _subend
.global _boot_data

.code16
_substart:

# =============================================================
# Real mode entry point
#
# CS.base is CS.selector << 4, and CS.selector is set to the vector of SIPI.
#
# Address is calculated by segment << 4 + offset.

.set REAL_SEG_SHIFT, 4
real_mode_entry:
  cli
  cld

  # Clear segment registers.
  xor   %ax, %ax
  mov   %ax, %ds
  mov   %ax, %es
  mov   %ax, %ss

  # Determine our own runtime physical base address.
  xor   %ebx, %ebx
  mov   %cs,  %bx
  shl   $REAL_SEG_SHIFT, %ebx

  # EBX = physical address of entry point.

  # Relocate the GDTR.base.
  lea   OFFSET(gdt_start)(%ebx), %eax
  mov   %eax, OFFSET(gdtr_base)(%ebx)
  lgdt  OFFSET(gdtr_limit)(%ebx)

  # Enter protected mode.
  mov   %cr0    , %eax
  or    $CR0_PE , %eax
  mov   %eax    , %cr0

  # Relocate the far jump target.
  lea   OFFSET(protected_mode_entry)(%ebx), %eax
  mov   %eax, OFFSET(farptr32)(%ebx)

  # Far jump to reload CS and enter protected mode.
  ljmpl *OFFSET(farptr32)(%ebx)

# =============================================================
# Protected mode entry point

.code32
protected_mode_entry:
  # Set up segment registers.
  mov   $SEG_DATA32,  %ax
  mov   %ax,  %ds
  mov   %ax,  %es
  mov   %ax,  %fs
  mov   %ax,  %gs
  mov   %ax,  %ss

  # Enable PAE.
  mov   %cr4,     %eax
  or    $CR4_PAE, %eax
  mov   %eax,     %cr4

  # Load CR3 with the physical address of the given page table.
  lea   OFFSET(_boot_data)(%ebx), %ecx
  mov   BOOTDATA_CR3(%ecx), %eax
  mov   %eax, %cr3

  # Enable IA-32e mode.
  mov   $MSR_EFER, %ecx
  rdmsr
  or    $(EFER_LME | EFER_NXE), %eax
  wrmsr

  # Enable paging.
  mov   %cr0,     %eax
  or    $CR0_PG,  %eax
  mov   %eax,     %cr0

  # Relocate the far jump target.
  lea   OFFSET(long_mode_entry)(%ebx), %eax
  mov   %eax, OFFSET(farptr64)(%ebx)

  # Far jump to reload CS and enter long mode.
  ljmp  *OFFSET(farptr64)(%ebx)

# =============================================================
# Long mode entry point

.code64
long_mode_entry:
  # Set up segment registers.
  mov   $SEG_DATA64, %ax
  mov   %ax,  %ds
  mov   %ax,  %es
  mov   %ax,  %fs
  mov   %ax,  %gs
  mov   %ax,  %ss

  # Switch stack to the one provided in the boot data.
  leaq  OFFSET(_boot_data)(%rbx), %r13
  movq  BOOTDATA_STACK(%r13), %rsp

  # Set up CPU.
  movabsq $setupHead, %rax
  callq   *%rax

  # Call entry point.
  movq  BOOTDATA_ENTRY(%r13), %rax
  jmp   *%rax

.Lhang:
  hlt
  jmp   .Lhang

# =============================================================
# Temporary GDT

.align 16
gdt_start:
  .quad 0x0000000000000000                # 0x00: NULL descriptor
  .quad 0x008F92000000FFFF                # 0x08: Data32
  .quad 0x00CF9A000000FFFF                # 0x10: Code32
  .quad 0x00CF92000000FFFF                # 0x18: Data64
  .quad 0x00AF9A000000FFFF                # 0x20: Code64
gdt_end:

# GDTR contents
gdtr_limit:
  .word gdt_end - gdt_start - 1
gdtr_base:
  .long RELOCATE

# =============================================================
# Far-jump targets

.align 8
farptr32:
  .long RELOCATE
  .word SEG_CODE32

farptr64:
  .long RELOCATE
  .word SEG_CODE64

# =============================================================
# Boot data

.align 8
_boot_data:
  .quad FILL  # CR3
  .quad FILL  # stack
  .quad FILL  # entry

_subend:
