#ifndef TEST_BOARD_H
#define TEST_BOARD_H
#include "wire.h"
typedef struct { unsigned id; } UART_HandleTypeDef;
typedef struct {
    WireParser parser;
    unsigned replaced,failed,control_count,control_head,control_tail;
    unsigned tx_bytes_per_second;
} BoardPort;
uint64_t board_us(void);
uint64_t board_boot_id(void);
uint64_t board_device_id(void);
void board_port_init(BoardPort *,UART_HandleTypeDef *,WireReceive,void *,uint16_t);
void board_port_rx(BoardPort *,UART_HandleTypeDef *);
void board_port_error(BoardPort *,UART_HandleTypeDef *);
void board_port_tx_done(BoardPort *,UART_HandleTypeDef *);
void board_port_poll(BoardPort *);
int board_port_send(BoardPort *,uint8_t,uint16_t,const uint8_t *,uint16_t,int);
#endif
