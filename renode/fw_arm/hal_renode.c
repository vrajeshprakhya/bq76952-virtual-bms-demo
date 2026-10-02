/*======================================================================
 * hal_renode.c -- Renode/STM32G0 platform: the xezim bridge is a
 * custom MMIO peripheral (Bridge.cs) at 0x6000_0000 (0x5000_0000 is
 * GPIOA on the G0), console is the v2-generation USART2.
 *====================================================================*/
#include "hal.h"

const char *hal_name = "Renode/STM32G0";

#define BR_PINS  (*(volatile uint32_t *)0x60000000u)  /* b0 SCL, b1 SDA pull */
#define BR_ADV   (*(volatile uint32_t *)0x60000004u)  /* advance board <ns>  */
#define BR_SDA   (*(volatile uint32_t *)0x60000008u)  /* sampled SDA         */
#define BR_FIN   (*(volatile uint32_t *)0x6000000Cu)  /* end the board sim   */

/* v2 USART register map (G0/F7 generation): CR1 @ 0x00, ISR @ 0x1C
 * (TXE = bit 7), TDR @ 0x28.  NOT the F4's v1 layout. */
#define USART2_CR1 (*(volatile uint32_t *)0x40004400u)
#define USART2_ISR (*(volatile uint32_t *)0x4000441Cu)
#define USART2_TDR (*(volatile uint32_t *)0x40004428u)

void hal_init(void)
{
    USART2_CR1 = (1u << 0) | (1u << 3);    /* UE | TE (v2 positions) */
}

void hal_set_pins(int scl, int sda_pull)
{
    BR_PINS = (uint32_t)((scl & 1) | ((sda_pull & 1) << 1));
}

void hal_adv(uint32_t ns)
{
    BR_ADV = ns;
}

int hal_sda(void)
{
    return (int)(BR_SDA & 1);
}

void hal_fin(void)
{
    BR_FIN = 1;
}

void hal_putc(char c)
{
    while (!(USART2_ISR & 0x80)) { }       /* TXE */
    USART2_TDR = (uint32_t)c;
}
