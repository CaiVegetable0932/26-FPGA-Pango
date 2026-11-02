#ifndef F1_LINK_H
#define F1_LINK_H
#include "board.h"
void F1_Link_Init(UART_HandleTypeDef *uart);
void F1_Link_Poll(void);
void F1_Link_Rx(UART_HandleTypeDef *uart);
void F1_Link_Error(UART_HandleTypeDef *uart);
void F1_Link_TxDone(UART_HandleTypeDef *uart);
void F1_Service(void);
#endif
