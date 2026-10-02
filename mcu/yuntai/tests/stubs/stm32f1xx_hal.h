#ifndef MOCK_STM32_HAL_H
#define MOCK_STM32_HAL_H
#include <stdint.h>
typedef struct { unsigned Instance; } UART_HandleTypeDef;
typedef enum { HAL_OK, HAL_ERROR, HAL_BUSY, HAL_TIMEOUT } HAL_StatusTypeDef;
uint32_t HAL_GetTick(void);
void HAL_Delay(uint32_t ms);
HAL_StatusTypeDef HAL_UART_Receive_IT(UART_HandleTypeDef *uart, uint8_t *data, uint16_t length);
HAL_StatusTypeDef HAL_UART_Transmit(UART_HandleTypeDef *uart, uint8_t *data, uint16_t length, uint32_t timeout);
static inline uint32_t __get_PRIMASK(void) { return 0U; }
static inline void __disable_irq(void) {}
static inline void __set_PRIMASK(uint32_t value) { (void)value; }
#endif
