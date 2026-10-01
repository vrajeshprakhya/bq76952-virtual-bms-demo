/* Minimal Cortex-M4 startup: vector table + reset handler. */
#include <stdint.h>

extern uint32_t _sbss, _ebss, _estack, _sdata, _edata, _sidata;
int main(void);

void Reset_Handler(void)
{
    uint32_t *src = &_sidata;
    for (uint32_t *p = &_sdata; p < &_edata; p++) *p = *src++;
    for (uint32_t *p = &_sbss; p < &_ebss; p++) *p = 0;
    main();
    for (;;) { }
}

__attribute__((section(".isr_vector"), used))
static const void *vectors[] = {
    &_estack,
    (void *)Reset_Handler,
};
