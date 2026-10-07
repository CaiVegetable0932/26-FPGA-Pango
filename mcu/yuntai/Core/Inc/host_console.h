#ifndef HOST_CONSOLE_H
#define HOST_CONSOLE_H

#include "stm32f1xx_hal.h"
#include <stdint.h>

#define HOST_CONSOLE_LINE_SIZE 64U

void Host_Console_Init(UART_HandleTypeDef *huart);
void Host_Console_RxCpltCallback(UART_HandleTypeDef *huart);
void Host_Console_ErrorCallback(UART_HandleTypeDef *huart);
uint8_t Host_Console_ReadLine(char *line, uint16_t capacity);
void Host_Console_Write(const char *text);

#endif
