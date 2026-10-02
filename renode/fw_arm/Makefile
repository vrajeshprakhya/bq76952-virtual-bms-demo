CC = $(HOME)/arm-gcc/bin/arm-none-eabi-gcc
CFLAGS = -mcpu=cortex-m0plus -mthumb -O2 -Wall -ffreestanding -nostdlib

fw.elf: main.c startup.c link.ld
	$(CC) $(CFLAGS) -Wl,-T,link.ld -Wl,--no-warn-rwx-segments \
	  -o $@ main.c startup.c -lgcc
	$(HOME)/arm-gcc/bin/arm-none-eabi-size $@

clean:
	rm -f fw.elf
