#ifndef F4_LINK_H
#define F4_LINK_H
#include "board.h"
void F4_Link_Init(void);
void F4_Link_Poll(void);
void F4_Link_Rx(UART_HandleTypeDef *uart);
void F4_Link_Error(UART_HandleTypeDef *uart);
void F4_Link_TxDone(UART_HandleTypeDef *uart);
/* Adapter calls keep the existing pulse driver, axis polarity and travel logic. */
void F4_AxesSnapshot(int32_t position[3], uint32_t limit[3], uint8_t *busy, uint8_t *valid);
uint8_t F4_AxesMove(uint8_t mask, const int32_t target[3], const uint16_t rpm[3]);
void F4_AxesStop(void);
uint8_t F4_ManualZero(uint8_t mask);
void F4_LegacyNotice(const char *text);
uint8_t F4_AxesResult(uint8_t mask);
void F4_Legacy(char *line, char *output, unsigned capacity);
void F4_ConfigChanged(void);
#endif
