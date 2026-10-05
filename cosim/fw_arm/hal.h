/*======================================================================
 * hal.h -- the five operations the BMS mission needs from a platform.
 * Two implementations, same mission logic:
 *   hal_renode.c  STM32G0 under Renode: bridge = custom MMIO
 *                 peripheral (the C# XezimBridge), console = v2 USART2
 *   hal_qemu.c    STM32F405 (netduino2) under mainline QEMU: bridge =
 *                 the line protocol spoken directly over USART1, whose
 *                 chardev is a TCP socket into the same xezim server;
 *                 console = v1 USART2
 * Board time advances ONLY through hal_adv -- on either platform.
 *====================================================================*/
#ifndef HAL_H
#define HAL_H
#include <stdint.h>

extern const char *hal_name;

void hal_init(void);
void hal_set_pins(int scl, int sda_pull);   /* sda_pull: 1 = pull low */
void hal_adv(uint32_t ns);                  /* advance BOARD time     */
int  hal_sda(void);                         /* bus as last settled    */
void hal_fin(void);                         /* end the board sim      */
void hal_putc(char c);                      /* console                */

#endif
