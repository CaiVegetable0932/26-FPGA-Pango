#include "usart.h"
/* Keep gateway setup independent of CubeMX's initialization ordering. */
void MX_Extra_UART_Init(void)
{
    MX_USART1_UART_Init();
    MX_USART6_UART_Init();
}
