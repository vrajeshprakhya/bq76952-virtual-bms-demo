CC = $(HOME)/arm-gcc/bin/arm-none-eabi-gcc
SIZE = $(HOME)/arm-gcc/bin/arm-none-eabi-size
CFLAGS = -mthumb -O2 -Wall -ffreestanding -nostdlib
LDFLAGS = -Wl,-T,link.ld -Wl,--no-warn-rwx-segments
# fault injection: make FAULT=OCD_SWAP / FAULT=REG_OFF1
ifneq ($(FAULT),)
CFLAGS += -DFAULT_$(FAULT)
endif

.PHONY: all fw.elf fw_qemu.elf clean

all: fw.elf fw_qemu.elf

# Renode / STM32G0 (Cortex-M0+): bridge = custom MMIO peripheral
fw.elf: main.c hal_renode.c startup.c link.ld hal.h
	$(CC) $(CFLAGS) -mcpu=cortex-m0plus $(LDFLAGS) \
	  -o $@ main.c hal_renode.c startup.c -lgcc
	$(SIZE) $@

# mainline QEMU / STM32F405 netduinoplus2 (Cortex-M4): bridge = USART1
fw_qemu.elf: main.c hal_qemu.c startup.c link.ld hal.h
	$(CC) $(CFLAGS) -mcpu=cortex-m4 $(LDFLAGS) \
	  -o $@ main.c hal_qemu.c startup.c -lgcc
	$(SIZE) $@

clean:
	rm -f fw.elf fw_qemu.elf
