ENTRY_ADDR = 0x80000;

PHDRS
{
    __boot_stack    PT_LOAD FLAGS(6); /* RW- */
    text            PT_LOAD FLAGS(5); /* R-X */
    rodata          PT_LOAD FLAGS(4); /* R-- */
    data            PT_LOAD FLAGS(6); /* RW- */
}

SECTIONS
{
    . = 0;

    .boot_stack (NOLOAD) :
    {
      . += ENTRY_ADDR;

      _boot_stack = .;
    } :__boot_stack

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

    .bss (NOLOAD) : ALIGN(16)
    {
      __bss_start = .;

      *(COMMON)
      *(.bss .bss.* .lbss)

      . = ALIGN(16);
      __bss_end = .;
    } :data

    __end = .;
}

