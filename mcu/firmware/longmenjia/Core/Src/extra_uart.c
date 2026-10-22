#include "usart.h"
#include "main.h"
/* 2026-10-21：USART2(PD5/PD6) 与 USART6(PC6/PC7) 已进入 .ioc 的 functionlistsort，
 * CubeMX 会直接在 main() 里生成 MX_USART2_UART_Init() / MX_USART6_UART_Init()。
 * 这里再初始化一次会与生成的调用重复，因此保留符号但不再重复初始化。
 * 若将来把它们从 functionlistsort 移出，需要在这里恢复显式调用。 */
void MX_Extra_UART_Init(void)
{
}

/* ============================================================================
 * 引脚活动自测（2026-10-22）
 *
 * 启动时把 PC0..PC13 临时改成输入+上拉，统计约 200 ms 内发生过电平翻转的脚，
 * 记到 F4_PinMask 里，然后恢复 UART4，正常继续启动。结果通过 GET_COUNTERS
 * 的 +24 字段读出（工具显示为 "PC 翻转掩码"），不需要额外串口。
 *
 * 用途：判断 F1 的 TX 信号实际落在 PORTC 的哪一个针脚上。
 * 注意：扫描期间 UART4 引脚被改作输入，所以必须放在 board_port_init 之前，
 *       且扫描后要用 DeInit+Init 把 AF 配置恢复回来。
 * ========================================================================== */
uint32_t F4_PinMask;

void F4_Pin_ScanOnce(void)
{
    GPIO_InitTypeDef g = {0};
    g.Mode = GPIO_MODE_INPUT;
    g.Pull = GPIO_PULLUP;
    for (uint32_t pin = 0; pin < 14U; ++pin)
    {
        g.Pin = 1U << pin;
        HAL_GPIO_Init(GPIOC, &g);
    }
    HAL_Delay(5);

    uint16_t prev = (uint16_t)(GPIOC->IDR & 0x3FFFU);
    uint16_t toggled = 0;
    for (uint32_t i = 0; i < 600000U; ++i)
    {
        uint16_t v = (uint16_t)(GPIOC->IDR & 0x3FFFU);
        toggled |= (uint16_t)(v ^ prev);
        prev = v;
    }
    F4_PinMask = toggled;

    /* 恢复 UART4 的复用配置（DeInit 让 State 归位，Init 才会重跑 MspInit） */
    (void)HAL_UART_DeInit(&huart4);
    MX_UART4_Init();
}
