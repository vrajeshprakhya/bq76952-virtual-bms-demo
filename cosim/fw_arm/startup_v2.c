/* Cortex-M0+ startup with a full vector table, so external
 * interrupts (the bridge's ALERT on IRQ 30) can be taken. */
#include <stdint.h>

extern uint32_t _sbss, _ebss, _estack, _sdata, _edata, _sidata;
int main(void);
void Alert_IRQHandler(void);

void Reset_Handler(void)
{
    uint32_t *src = &_sidata;
    for (uint32_t *p = &_sdata; p < &_edata; p++) *p = *src++;
    for (uint32_t *p = &_sbss; p < &_ebss; p++) *p = 0;
    main();
    for (;;) { }
}

static void Default_Handler(void) { for (;;) { } }

__attribute__((section(".isr_vector"), used))
static const void *vectors[16 + 32] = {
    [0]  = &_estack,
    [1]  = (void *)Reset_Handler,
    [2]  = (void *)Default_Handler,   /* NMI */
    [3]  = (void *)Default_Handler,   /* HardFault */
    [11] = (void *)Default_Handler,   /* SVCall */
    [14] = (void *)Default_Handler,   /* PendSV */
    [15] = (void *)Default_Handler,   /* SysTick */
    [16 + 30] = (void *)Alert_IRQHandler,
};
