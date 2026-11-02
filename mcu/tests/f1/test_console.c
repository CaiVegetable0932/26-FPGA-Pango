#include "host_console.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static uint8_t *receive;
static UART_HandleTypeDef uart;
HAL_StatusTypeDef HAL_UART_Receive_IT(UART_HandleTypeDef *u, uint8_t *p, uint16_t n)
{ (void)u; assert(n == 1); receive = p; return HAL_OK; }
HAL_StatusTypeDef HAL_UART_Transmit(UART_HandleTypeDef *u, uint8_t *p, uint16_t n, uint32_t t)
{ (void)u; (void)p; (void)n; (void)t; return HAL_OK; }
static void Input(const char *s)
{ while (*s) { *receive = (uint8_t)*s++; Host_Console_RxCpltCallback(&uart); } }
int main(void)
{
    char line[64]; Host_Console_Init(&uart);
    Input("move 1\r\n"); assert(Host_Console_ReadLine(line, sizeof(line)) && !strcmp(line,"move 1"));
    assert(!Host_Console_ReadLine(line, sizeof(line)));
    Input("move 3\b2\n"); assert(Host_Console_ReadLine(line, sizeof(line)) && !strcmp(line,"move 2"));
    for (unsigned i=0; i<80; i++) Input("a");
    Input("\n"); assert(!Host_Console_ReadLine(line, sizeof(line)));
    Input("status\n"); assert(Host_Console_ReadLine(line, sizeof(line)) && !strcmp(line,"status"));
    puts("PASS: CRLF, backspace, overflow discard and recovery"); return 0;
}
