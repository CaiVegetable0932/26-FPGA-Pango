#ifndef HOST_CONSOLE_H
#define HOST_CONSOLE_H

#include "stm32f1xx_hal.h"
#include <stdint.h>

/* 人机文本控制台。
 *
 * 当前构建不绑定任何串口：USART1 已交给 F4 代理链路（见 f1_link.c），main.c
 * 不调用 Host_Console_Init()，HAL_UART_RxCpltCallback() 只把非舵机口分派给
 * F1_Link_Rx()。于是 g_hostUart 恒为 NULL：
 *   - Host_Console_Write() 直接返回，gimbal_test.c 的 Reply(...) 文本被静默丢弃；
 *   - Host_Console_ReadLine() 永远返回 0，该文件里的 Command() 是死路径。
 * 排障请读 F1_STATE，不要指望串口文本。
 *
 * 本模块与 tests/f1/test_console.c 保留为可独立测试的组件。若要恢复人读串口，
 * 需另占一个空闲 UART（如 USART2 的 PA2/PA3），并同时补上 Init 调用与回调分派。
 */

#define HOST_CONSOLE_LINE_SIZE 64U

void Host_Console_Init(UART_HandleTypeDef *huart);
void Host_Console_RxCpltCallback(UART_HandleTypeDef *huart);
void Host_Console_ErrorCallback(UART_HandleTypeDef *huart);
uint8_t Host_Console_ReadLine(char *line, uint16_t capacity);
void Host_Console_Write(const char *text);

#endif
