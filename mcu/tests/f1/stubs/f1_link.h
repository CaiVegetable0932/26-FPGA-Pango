#ifndef F1_LINK_H_TEST
#define F1_LINK_H_TEST
#include "stm32f1xx_hal.h"
void F1_Link_Rx(UART_HandleTypeDef *);
void F1_Link_Error(UART_HandleTypeDef *);
void F1_Link_TxDone(UART_HandleTypeDef *);
void F1_Service(void);
#endif
