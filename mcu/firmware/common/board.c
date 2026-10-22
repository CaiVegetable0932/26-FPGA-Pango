#include "board.h"
#include <string.h>

uint64_t board_us(void)
{
    static uint32_t previous;
    static uint64_t elapsed;
    static uint8_t initialized;
    uint32_t mask=__get_PRIMASK(); __disable_irq();
    if (!initialized) {
        CoreDebug->DEMCR|=CoreDebug_DEMCR_TRCENA_Msk;
        DWT->CYCCNT=0; DWT->CTRL|=DWT_CTRL_CYCCNTENA_Msk; initialized=1;
    }
    uint32_t current=DWT->CYCCNT;
    elapsed+=(uint32_t)(current-previous); previous=current;
    uint64_t result=elapsed/(SystemCoreClock/1000000U);
    __set_PRIMASK(mask); return result;
}
uint64_t board_device_id(void)
{
    return ((uint64_t)HAL_GetUIDw0()<<32) ^ HAL_GetUIDw1() ^ ((uint64_t)HAL_GetUIDw2()<<1);
}

/* Two-bank append journal: commit magic last, never erase the newest record.
 * Reserved flash is excluded by each linker script. Exhaustion fails closed. */
uint64_t board_boot_id(void)
{
#ifdef MCU_F1
    const uint32_t bases[2]={0x0800f800U,0x0800fc00U};
    const uint32_t size=1024U;
#else
    const uint32_t bases[2]={0x080c0000U,0x080e0000U};
    const uint32_t size=128U*1024U;
#endif
    uint64_t highest=0;
    unsigned newest=0;
    for (unsigned bank=0;bank<2;bank++) {
        for (uint32_t offset=0;offset<size;offset+=16) {
            const uint32_t *r=(const uint32_t *)(uintptr_t)(bases[bank]+offset);
            uint64_t value=(uint64_t)r[1]|(uint64_t)r[2]<<32;
            uint16_t crc=wire_crc((const uint8_t *)(r+1),8);
            uint32_t check=(uint32_t)crc|((uint32_t)(uint16_t)~crc<<16);
            if (r[0]==0x424f4f54U && r[3]==check && value>highest) {
                highest=value; newest=bank;
            }
        }
    }
    if (highest==UINT64_MAX || HAL_FLASH_Unlock()!=HAL_OK) return 0;
    uint32_t address=0;
    for (uint32_t offset=0;offset<size;offset+=16) {
        const uint32_t *r=(const uint32_t *)(uintptr_t)(bases[newest]+offset);
        if (r[0]==UINT32_MAX && r[1]==UINT32_MAX && r[2]==UINT32_MAX && r[3]==UINT32_MAX) {
            address=bases[newest]+offset; break;
        }
    }
    if (!address) {
        FLASH_EraseInitTypeDef erase={0}; uint32_t error=0;
#ifdef MCU_F1
        erase.TypeErase=FLASH_TYPEERASE_PAGES; erase.PageAddress=bases[1-newest]; erase.NbPages=1;
#else
        erase.TypeErase=FLASH_TYPEERASE_SECTORS; erase.Sector=10U+1U-newest;
        erase.NbSectors=1; erase.VoltageRange=FLASH_VOLTAGE_RANGE_3;
#endif
        if (HAL_FLASHEx_Erase(&erase,&error)!=HAL_OK) { HAL_FLASH_Lock(); return 0; }
        address=bases[1-newest];
    }
    uint64_t value=highest+1;
    uint32_t words[4]={0x424f4f54U,(uint32_t)value,(uint32_t)(value>>32),0};
    uint16_t crc=wire_crc((const uint8_t *)(words+1),8);
    words[3]=(uint32_t)crc|((uint32_t)(uint16_t)~crc<<16);
    int ok=1;
    for (unsigned j=1;j<=4;j++) {
        unsigned i=j%4;
#ifdef MCU_F1
        ok &= HAL_FLASH_Program(FLASH_TYPEPROGRAM_WORD,address+4*i,words[i])==HAL_OK;
#else
        ok &= HAL_FLASH_Program(FLASH_TYPEPROGRAM_WORD,address+4*i,words[i])==HAL_OK;
#endif
        if (!ok) break;
    }
    HAL_FLASH_Lock();
    return ok && memcmp((const void *)(uintptr_t)address,words,16)==0 ? value : 0;
}

void board_port_init(BoardPort *p, UART_HandleTypeDef *uart, WireReceive cb, void *ctx, uint16_t timeout)
{
    memset(p,0,sizeof(*p)); p->uart=uart; wire_init(&p->parser,timeout,cb,ctx);
    p->failed=HAL_UART_Receive_IT(uart,&p->rx_byte,1)!=HAL_OK;
}
/* 循环 DMA 接收：不再逐字节进中断，主循环按 DMA 写指针批量取字节喂解析器。
 * 适用场景见 board.h：高码率端口（F4 的 F1 代理口 460800 约 2.76 万字节/秒）。 */
void board_port_init_dma(BoardPort *p, UART_HandleTypeDef *uart, WireReceive cb, void *ctx, uint16_t timeout)
{
    memset(p,0,sizeof(*p)); p->uart=uart; wire_init(&p->parser,timeout,cb,ctx);
    p->dma_mode=1; p->dma_last=0;
    if (uart->hdmarx==NULL ||
        HAL_UART_Receive_DMA(uart,p->dma_buf,(uint16_t)sizeof(p->dma_buf))!=HAL_OK) {
        /* .ioc 里还没给这个 UART 配 DMA 时，安静地退回中断方式 */
        p->dma_mode=0;
        p->failed=HAL_UART_Receive_IT(uart,&p->rx_byte,1)!=HAL_OK;
    }
}
void board_port_rx(BoardPort *p, UART_HandleTypeDef *uart)
{
    if (uart!=p->uart) return;
    if (p->failed || uart->ErrorCode!=HAL_UART_ERROR_NONE) {
        p->failed=1;
        __HAL_UART_DISABLE_IT(uart,UART_IT_RXNE);
        __HAL_UART_DISABLE_IT(uart,UART_IT_PE);
        __HAL_UART_DISABLE_IT(uart,UART_IT_ERR);
        return;
    }
    uint16_t next=(uint16_t)((p->head+1)%512);
    if (next==p->tail) p->failed=1;
    else { p->rx[p->head]=p->rx_byte; p->rx_tick[p->head]=board_us(); p->head=next; ++p->rx_total; }
    if (HAL_UART_Receive_IT(uart,&p->rx_byte,1)!=HAL_OK) p->failed=1;
}
void board_port_error(BoardPort *p, UART_HandleTypeDef *uart)
{
    if (uart!=p->uart) return;
    p->failed=1;
    __HAL_UART_DISABLE_IT(uart,UART_IT_RXNE);
    __HAL_UART_DISABLE_IT(uart,UART_IT_PE);
    __HAL_UART_DISABLE_IT(uart,UART_IT_ERR);
}
void board_port_tx_done(BoardPort *p, UART_HandleTypeDef *uart) { if (uart==p->uart) p->transmitting=0; }
int board_port_send(BoardPort *p, uint8_t cmd, uint16_t seq, const uint8_t *data, uint16_t n, int state)
{
    if (n+10U>sizeof(p->controls[0])) return 0;
    if (state) {
        if (n+10U>sizeof(p->state)) return 0;
        if (p->state_size) wire_count(&p->replaced);
        p->state_size=(uint16_t)wire_frame(p->state,cmd,seq,data,n); return 1;
    }
    if (p->control_count==4) return 0;
    unsigned i=p->control_head;
    p->control_size[i]=(uint16_t)wire_frame(p->controls[i],cmd,seq,data,n);
    p->control_head=(uint8_t)((i+1)%4); ++p->control_count; return 1;
}
void board_port_poll(BoardPort *p)
{
    if (p->dma_mode && p->uart->hdmarx) {
        if (p->failed) {
            /* 溢出等错误会让 HAL 中止 DMA，这里重新武装 */
            uint32_t mask=__get_PRIMASK(); __disable_irq();
            wire_count(&p->overrun);
            HAL_UART_AbortReceive(p->uart); __HAL_UART_CLEAR_OREFLAG(p->uart);
            p->parser.used=0; p->dma_last=0;
            p->failed=HAL_UART_Receive_DMA(p->uart,p->dma_buf,(uint16_t)sizeof(p->dma_buf))!=HAL_OK;
            __set_PRIMASK(mask);
        }
        /* 循环 DMA：这一轮新增了多少字节由 DMA 剩余计数反推 */
        uint16_t pos=(uint16_t)(sizeof(p->dma_buf)-__HAL_DMA_GET_COUNTER(p->uart->hdmarx));
        if (pos>sizeof(p->dma_buf)) pos=0;
        uint64_t tick=board_us();
        for (unsigned budget=0;budget<1024 && p->dma_last!=pos;budget++) {
            uint8_t byte=p->dma_buf[p->dma_last];
            p->dma_last=(uint16_t)((p->dma_last+1U)%sizeof(p->dma_buf));
            ++p->rx_total;
            wire_feed(&p->parser,byte,tick);
        }
    } else {
        if (p->failed) {
            uint32_t mask=__get_PRIMASK(); __disable_irq();
            wire_count(&p->overrun);
            HAL_UART_AbortReceive(p->uart); __HAL_UART_CLEAR_OREFLAG(p->uart);
            p->tail=p->head; p->parser.used=0;
            p->failed=HAL_UART_Receive_IT(p->uart,&p->rx_byte,1)!=HAL_OK;
            __set_PRIMASK(mask);
        } else if (p->uart->RxState==HAL_UART_STATE_READY) {
            /* 自愈（2026-10-22）：HAL 在 ORE 等错误后会把 RxState 打回 READY 并停止接收，
             * 若不重新武装，该端口会永久静默（F1 的 USART1 实测就是 RxState=0x20/RXNEIE=0）。
             * 这里只要发现"空闲且没在收"就重新武装。 */
            __HAL_UART_CLEAR_OREFLAG(p->uart);
            p->uart->ErrorCode=HAL_UART_ERROR_NONE;
            if (HAL_UART_Receive_IT(p->uart,&p->rx_byte,1)!=HAL_OK) p->failed=1;
        }
    }
    for (unsigned budget=0;budget<512 && p->tail!=p->head;budget++) {
        unsigned i=p->tail; uint8_t byte=p->rx[i]; uint64_t tick=p->rx_tick[i];
        /* A queued parser callback must not renew a lease using an old request. */
        if (board_us()-tick>p->parser.timeout_ms*1000ULL) {
            p->tail=(uint16_t)((i+1)%512); p->parser.used=0; wire_count(&p->parser.timeouts); continue;
        }
        p->tail=(uint16_t)((i+1)%512); wire_feed(&p->parser,byte,tick);
    }
    wire_poll(&p->parser,board_us());
    if (!p->transmitting && (!p->tx_bytes_per_second || board_us()>=p->tx_budget_us)) {
        uint16_t n=0;
        if (p->state_size && board_us()-p->last_state_tx>=7500) {
            n=p->state_size; memcpy(p->tx,p->state,n); p->state_size=0; p->last_state_tx=board_us();
        } else if (p->control_count) {
            unsigned i=p->control_tail; n=p->control_size[i]; memcpy(p->tx,p->controls[i],n);
            p->control_tail=(uint8_t)((i+1)%4); --p->control_count;
        } else if (p->state_size) { n=p->state_size; memcpy(p->tx,p->state,n); p->state_size=0; p->last_state_tx=board_us(); }
        if (n) {
            if (p->tx[3]==0x82 && wire_u16(p->tx+6)==40) {
                wire_put64(p->tx+40,board_us());
                wire_put16(p->tx+48,wire_crc(p->tx+2,46));
            }
            p->transmitting=1;
            if (p->tx_bytes_per_second) p->tx_budget_us=board_us()+((uint64_t)n*1000000+p->tx_bytes_per_second-1)/p->tx_bytes_per_second;
            /* DMA 模式下 failed 只表示接收需要重新武装，发送失败不得误触发接收复位 */
            if (HAL_UART_Transmit_IT(p->uart,p->tx,n)!=HAL_OK) { p->transmitting=0; if(!p->dma_mode) p->failed=1; ++p->tx_fail; }
            else ++p->tx_ok;
        }
    }
}
