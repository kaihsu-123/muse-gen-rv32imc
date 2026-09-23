/* sim.ld -- bare-metal linker script for the functional testbench.
 *
 * Memory map (matches tb_rv32imc.v, 128 KiB unified memory):
 *   0x00000000 : program entry (_start), .text / .rodata / .data / .bss
 *   0x0001F000 : stack top (grows down), 4 KiB reserved
 *   .tohost    : riscv-tests tohost/fromhost section (address found via nm)
 */
OUTPUT_ARCH( "riscv" )
ENTRY( _start )

SECTIONS
{
  . = 0x00000000;

  .text.init : {
    *(.text.init)
  }

  . = ALIGN(0x1000);
  .text : {
    *(.text)
    *(.text.*)
  }

  .rodata : {
    *(.rodata)
    *(.rodata.*)
  }

  . = ALIGN(4);
  .data : {
    *(.data)
    *(.data.*)
    *(.sdata)
    *(.sdata.*)
  }

  .bss (NOLOAD) : {
    *(.bss)
    *(.bss.*)
    *(COMMON)
  }

  . = ALIGN(64);
  .tohost : {
    *(.tohost)
  }

  . = ALIGN(4);
  _end = .;

  /* 4 KiB stack at the top of the 128 KiB memory */
  _stack_top = 0x0001F000;
}
