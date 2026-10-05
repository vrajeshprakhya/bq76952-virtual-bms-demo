/*======================================================================
 * hal_qemu.c -- mainline-QEMU/STM32F405 platform (machine
 * netduinoplus2, zero QEMU modifications).
 *
 * Mainline QEMU has no generic "remote MMIO" hook, so the bridge
 * rides a spare UART -- the pattern pre-silicon teams use to bolt a
 * model or HIL channel onto whatever port exists.  USART1's chardev
 * is a TCP socket into the SAME xezim bridge server the Renode build
 * talks to; this file speaks the line protocol ("S scl sda" / "A ns"
 * / "F", each acked "K <sda>") through USART1's registers.  USART2
 * stays the console.  Both are v1-generation USARTs (SR @ 0x00 with
 * TXE=b7 RXNE=b5, DR @ 0x04, CR1 @ 0x0C with UE=b13 TE=b3 RE=b2).
 *
 * The lockstep contract is untouched: board time advances only on
 * 'A' commands, every command is acked with the settled SDA.
 *====================================================================*/
#include "hal.h"

const char *hal_name = "QEMU/STM32F405";

#define U1_SR  (*(volatile uint32_t *)0x40011000u)   /* bridge */
#define U1_DR  (*(volatile uint32_t *)0x40011004u)
#define U1_CR1 (*(volatile uint32_t *)0x4001100Cu)
#define U2_SR  (*(volatile uint32_t *)0x40004400u)   /* console */
#define U2_DR  (*(volatile uint32_t *)0x40004404u)
#define U2_CR1 (*(volatile uint32_t *)0x4000440Cu)
#define CR1_EN ((1u << 13) | (1u << 3) | (1u << 2))  /* UE|TE|RE */

static int last_sda = 1;

static void u1_putc(char c)
{
    while (!(U1_SR & 0x80)) { }            /* TXE */
    U1_DR = (uint32_t)c;
}
static char u1_getc(void)
{
    while (!(U1_SR & 0x20)) { }            /* RXNE */
    return (char)(U1_DR & 0xff);
}
static void put_dec(uint32_t v)
{
    char b[12]; int i = 0;
    if (!v) { u1_putc('0'); return; }
    while (v) { b[i++] = (char)('0' + v % 10); v /= 10; }
    while (i) u1_putc(b[--i]);
}
static void read_ack(void)                 /* "K <sda>\n" */
{
    char c, last = '1';
    while ((c = u1_getc()) != '\n')
        if (c == '0' || c == '1') last = c;
    last_sda = (last == '1');
}

void hal_init(void)
{
    U1_CR1 = CR1_EN;
    U2_CR1 = CR1_EN;
}

void hal_set_pins(int scl, int sda_pull)
{
    u1_putc('S'); u1_putc(' ');
    u1_putc((char)('0' + (scl & 1))); u1_putc(' ');
    u1_putc((char)('0' + (sda_pull & 1))); u1_putc('\n');
    read_ack();
}

void hal_adv(uint32_t ns)
{
    u1_putc('A'); u1_putc(' ');
    put_dec(ns); u1_putc('\n');
    read_ack();
}

int hal_sda(void)
{
    return last_sda;
}

void hal_fin(void)
{
    u1_putc('F'); u1_putc('\n');
    read_ack();
    /* semihosting SYS_EXIT so QEMU terminates cleanly */
    register uint32_t r0 asm("r0") = 0x18;         /* SYS_EXIT      */
    register uint32_t r1 asm("r1") = 0x20026;      /* ApplicationExit */
    asm volatile("bkpt 0xAB" :: "r"(r0), "r"(r1) : "memory");
}

void hal_putc(char c)
{
    while (!(U2_SR & 0x80)) { }            /* TXE */
    U2_DR = (uint32_t)c;
}
