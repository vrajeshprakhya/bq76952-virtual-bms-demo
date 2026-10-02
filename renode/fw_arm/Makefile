CC = $(HOME)/arm-gcc/bin/arm-none-eabi-gcc
CFLAGS = -mcpu=cortex-m0plus -mthumb -O2 -Wall -ffreestanding -nostdlib
# fault injection: make FAULT=OCD_SWAP / FAULT=REG_OFF1
ifneq ($(FAULT),)
CFLAGS += -DFAULT_$(FAULT)
endif

.PHONY: fw.elf

fw.elf: main.c startup.c link.ld
	$(CC) $(CFLAGS) -Wl,-T,link.ld -Wl,--no-warn-rwx-segments \
	  -o $@ main.c startup.c -lgcc
	$(HOME)/arm-gcc/bin/arm-none-eabi-size $@

clean:
	rm -f fw.elf
