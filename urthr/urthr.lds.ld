#include <constants.autogen.h>

STACK_SIZE          = 0x5000;

PHDRS {
    text            PT_LOAD FLAGS(5); /* R-X */
    rodata          PT_LOAD FLAGS(4); /* R-- */
    data            PT_LOAD FLAGS(6); /* RW- */
    bss             PT_LOAD FLAGS(6); /* RW- */
    __early_stack   PT_LOAD FLAGS(6); /* RW- */
}

SECTIONS
{
    . = V_KERNEL_START;

    .text : ALIGN(4K)
    {
      KEEP(*(.text.boot))
      *(.text .text.* .ltext)
    } :text

    .rodata : ALIGN(4K)
    {
      *(.rodata .rodata.*)
    } :text

    .data : ALIGN(4K)
    {
      *(.data .data.* .ldata)
    } :data

    .got : ALIGN(8)
    {
      *(.got .got.*)
    } :data

    .bss (NOLOAD) : ALIGN(16)
    {
      __bss_start = .;

      *(COMMON)
      *(.bss .bss.* .lbss)

      . = ALIGN(16);
      __bss_end = .;
    } :data

    __early_stack (NOLOAD) : ALIGN(4K) {
      . += STACK_SIZE;
      _boot_stack  = .;
    } :__early_stack

    __end = .;
}
