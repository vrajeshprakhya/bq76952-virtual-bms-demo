/* STM32G0-class memory map (matches Renode's stm32g0.repl) */
MEMORY
{
  FLASH (rx) : ORIGIN = 0x08000000, LENGTH = 128K
  RAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 48K
}

_estack = ORIGIN(RAM) + LENGTH(RAM);

SECTIONS
{
  .text :
  {
    KEEP(*(.isr_vector))
    *(.text*)
    *(.rodata*)
  } > FLASH

  _sidata = LOADADDR(.data);
  .data : AT (ADDR(.text) + SIZEOF(.text))
  {
    _sdata = .;
    *(.data*)
    _edata = .;
  } > RAM

  .bss :
  {
    _sbss = .;
    *(.bss*)
    *(COMMON)
    _ebss = .;
  } > RAM
}
