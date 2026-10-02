#include "host_console.h"

#include <string.h>

static UART_HandleTypeDef *g_hostUart;
static uint8_t g_rxByte;
static char g_line[HOST_CONSOLE_LINE_SIZE];
static char g_pendingLine[HOST_CONSOLE_LINE_SIZE];
static volatile uint16_t g_lineLength;
static volatile uint8_t g_lineReady;
static uint8_t g_discardLine;

void Host_Console_Init(UART_HandleTypeDef *huart)
{
    g_hostUart = huart;
    g_lineLength = 0U;
    g_lineReady = 0U;
    g_discardLine = 0U;
    HAL_UART_Receive_IT(g_hostUart, &g_rxByte, 1U);
}

void Host_Console_RxCpltCallback(UART_HandleTypeDef *huart)
{
    if (huart != g_hostUart) {
        return;
    }

    if (g_rxByte == '\r' || g_rxByte == '\n') {
        if (g_lineLength > 0U && !g_lineReady && !g_discardLine) {
            g_line[g_lineLength] = '\0';
            memcpy(g_pendingLine, g_line, g_lineLength + 1U);
            g_lineReady = 1U;
        }
        g_lineLength = 0U;
        g_discardLine = 0U;
    } else if (g_rxByte == '\b' || g_rxByte == 0x7FU) {
        if (g_lineLength > 0U) {
            g_lineLength--;
        }
    } else if (g_lineLength < HOST_CONSOLE_LINE_SIZE - 1U && !g_discardLine) {
        g_line[g_lineLength++] = (char)g_rxByte;
    } else {
        g_discardLine = 1U;
    }

    HAL_UART_Receive_IT(g_hostUart, &g_rxByte, 1U);
}

uint8_t Host_Console_ReadLine(char *line, uint16_t capacity)
{
    uint16_t length;

    if (!line || capacity == 0U || !g_lineReady) {
        return 0U;
    }

    uint32_t mask = __get_PRIMASK();
    __disable_irq();
    length = (uint16_t)strlen(g_pendingLine);
    if (length >= capacity) {
        length = capacity - 1U;
    }
    memcpy(line, g_pendingLine, length);
    line[length] = '\0';
    g_lineReady = 0U;
    __set_PRIMASK(mask);
    return 1U;
}

void Host_Console_Write(const char *text)
{
    if (g_hostUart && text) {
        HAL_UART_Transmit(g_hostUart, (uint8_t *)text,
                          (uint16_t)strlen(text), 1000U);
    }
}

void Host_Console_ErrorCallback(UART_HandleTypeDef *huart)
{
    if (huart == g_hostUart) {
        g_lineLength = 0U;
        g_discardLine = 1U;
        HAL_UART_Receive_IT(huart, &g_rxByte, 1U);
    }
}
