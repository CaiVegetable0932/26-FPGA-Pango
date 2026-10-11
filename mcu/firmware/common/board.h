#ifndef MCU_BOARD_H
#define MCU_BOARD_H
#ifdef MCU_F1
#include "stm32f1xx_hal.h"
#else
#include "stm32f4xx_hal.h"
#endif
#include "wire.h"
/* Microsecond clock must be polled at least once per DWT counter wrap. */
uint64_t board_us(void);
uint64_t board_boot_id(void);
uint64_t board_device_id(void);
typedef struct {
    UART_HandleTypeDef *uart;
    WireParser parser;
    uint8_t rx_byte, rx[512];
    uint64_t rx_tick[512];
    volatile uint16_t head, tail;
    volatile uint8_t failed;
    uint8_t tx[320], controls[4][320], state[160];
    uint16_t control_size[4], state_size;
    uint8_t control_head, control_tail, control_count;
    volatile uint8_t transmitting;
    uint32_t replaced, overrun;
    uint64_t last_state_tx;
    uint64_t tx_budget_us;
    uint32_t tx_bytes_per_second;
} BoardPort;
void board_port_init(BoardPort *p, UART_HandleTypeDef *uart, WireReceive callback, void *ctx, uint16_t timeout);
void board_port_rx(BoardPort *p, UART_HandleTypeDef *uart);
void board_port_error(BoardPort *p, UART_HandleTypeDef *uart);
void board_port_tx_done(BoardPort *p, UART_HandleTypeDef *uart);
void board_port_poll(BoardPort *p);
int board_port_send(BoardPort *p, uint8_t cmd, uint16_t seq, const uint8_t *data, uint16_t n, int state);
#endif
