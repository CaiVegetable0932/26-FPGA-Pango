#ifndef TEST_STM32F4XX_HAL_H
#define TEST_STM32F4XX_HAL_H

#include <stdint.h>
#include <stddef.h>

typedef enum { HAL_OK, HAL_ERROR, HAL_BUSY } HAL_StatusTypeDef;
typedef enum { TIM2_IRQn, TIM3_IRQn, TIM4_IRQn, TIM5_IRQn, USART3_IRQn } IRQn_Type;
typedef struct
{
    uint32_t CR1, DIER, CCMR1, CNT, SR, ARR, CCR1, CCR2, EGR, PSC, CCER, CR2, SMCR;
} TIM_TypeDef;
typedef enum { HAL_TIM_STATE_RESET, HAL_TIM_STATE_READY } HAL_TIM_StateTypeDef;
typedef struct { TIM_TypeDef *Instance; HAL_TIM_StateTypeDef State; } TIM_HandleTypeDef;
typedef struct { uint32_t BSRR; } GPIO_TypeDef;
typedef struct { uint32_t CFGR, CSR; } RCC_TypeDef;
typedef struct { uint32_t APB1FZ; } DBGMCU_TypeDef;
typedef struct { uint32_t Pin, Mode, Pull, Speed, Alternate; } GPIO_InitTypeDef;
typedef struct { uint32_t SR, DR, CR1, CR3; } USART_TypeDef;
typedef enum { HAL_UART_STATE_READY, HAL_UART_STATE_BUSY_RX } HAL_UART_StateTypeDef;
typedef struct
{
    USART_TypeDef *Instance;
    HAL_UART_StateTypeDef RxState;
    uint32_t ErrorCode;
} UART_HandleTypeDef;
void HAL_UART_IRQHandler(UART_HandleTypeDef *uart);
HAL_StatusTypeDef HAL_UART_Receive_IT(UART_HandleTypeDef *uart, uint8_t *data, uint16_t size);
HAL_StatusTypeDef HAL_UART_Transmit(UART_HandleTypeDef *uart, uint8_t *data, uint16_t size, uint32_t timeout);
HAL_StatusTypeDef HAL_UART_AbortReceive(UART_HandleTypeDef *uart);
HAL_StatusTypeDef HAL_UART_Abort(UART_HandleTypeDef *uart);

#define RESET 0U
#define HAL_UART_ERROR_NONE 0U
#define HAL_UART_ERROR_ORE 8U
#define USART_SR_PE 1U
#define USART_SR_FE 2U
#define USART_SR_NE 4U
#define USART_SR_ORE 8U
#define USART_SR_RXNE 32U
#define UART_IT_RXNE 32U
#define UART_IT_PE 256U
#define UART_IT_ERR 1U
#define __HAL_UART_DISABLE_IT(uart, it) do { \
    if ((it) == UART_IT_ERR) (uart)->Instance->CR3 &= ~(it); \
    else (uart)->Instance->CR1 &= ~(it); \
} while (0)
#define __HAL_UART_GET_IT_SOURCE(uart, it) ((uart)->Instance->CR1 & (it))
#define __HAL_UART_CLEAR_OREFLAG(uart) ((uart)->Instance->SR &= \
    ~(USART_SR_PE | USART_SR_FE | USART_SR_NE | USART_SR_ORE | USART_SR_RXNE))

extern TIM_TypeDef mock_timers[4];
extern GPIO_TypeDef mock_gpio[4];
extern RCC_TypeDef mock_rcc;
extern DBGMCU_TypeDef mock_debug;
extern uint32_t mock_primask, mock_ipsr, mock_pclk, mock_delay;

#define TIM2 (&mock_timers[0])
#define TIM3 (&mock_timers[1])
#define TIM4 (&mock_timers[2])
#define TIM5 (&mock_timers[3])
#define GPIOA (&mock_gpio[0])
#define GPIOB (&mock_gpio[1])
#define GPIOC (&mock_gpio[2])
#define GPIOG (&mock_gpio[3])
#define RCC (&mock_rcc)
#define DBGMCU (&mock_debug)
#define GPIO_PIN_0 1U
#define GPIO_PIN_1 2U
#define GPIO_PIN_2 4U
#define GPIO_PIN_3 8U
#define GPIO_PIN_4 16U
#define GPIO_PIN_5 32U
#define GPIO_PIN_6 64U
#define GPIO_PIN_7 128U
#define GPIO_PIN_8 256U
#define GPIO_PIN_10 1024U
#define GPIO_PIN_11 2048U
#define GPIO_AF1_TIM2 1U
#define GPIO_AF2_TIM3 2U
#define GPIO_AF2_TIM4 2U
#define GPIO_AF2_TIM5 2U
#define GPIO_MODE_OUTPUT_PP 1U
#define GPIO_MODE_AF_PP 2U
#define GPIO_PULLDOWN 2U
#define GPIO_SPEED_FREQ_LOW 0U
#define TIM_CR1_CEN 1U
#define TIM_CR1_URS 4U
#define TIM_CR1_ARPE 128U
#define TIM_CR2_MMS 112U
#define TIM_TRGO_ENABLE 16U
#define TIM_SMCR_SMS 7U
#define TIM_SMCR_TS 112U
#define TIM_SLAVEMODE_GATED 5U
#define TIM_TS_ITR1 16U
#define TIM_DIER_UIE 1U
#define TIM_SR_UIF 1U
#define TIM_EGR_UG 1U
#define TIM_CCMR1_OC1M_2 64U
#define TIM_CCMR1_OC1M 112U
#define TIM_CCMR1_OC1PE 8U
#define TIM_CCER_CC1E 1U
#define TIM_CCER_CC2E 16U
#define RCC_CFGR_PPRE1 0x1C00U
#define DBGMCU_APB1_FZ_DBG_TIM2_STOP 1U
#define DBGMCU_APB1_FZ_DBG_TIM3_STOP 2U
#define DBGMCU_APB1_FZ_DBG_TIM4_STOP 4U
#define DBGMCU_APB1_FZ_DBG_TIM5_STOP 8U

#define __HAL_RCC_GPIOA_CLK_ENABLE() ((void)0)
#define __HAL_RCC_GPIOB_CLK_ENABLE() ((void)0)
#define __HAL_RCC_GPIOC_CLK_ENABLE() ((void)0)
#define __HAL_RCC_TIM2_CLK_ENABLE() ((void)0)
#define __HAL_RCC_TIM3_CLK_ENABLE() ((void)0)
#define __HAL_RCC_TIM4_CLK_ENABLE() ((void)0)
#define __HAL_RCC_TIM5_CLK_ENABLE() ((void)0)
#define __HAL_RCC_TIM2_FORCE_RESET() ((void)0)
#define __HAL_RCC_TIM2_RELEASE_RESET() ((void)0)
#define __HAL_RCC_TIM3_FORCE_RESET() ((void)0)
#define __HAL_RCC_TIM3_RELEASE_RESET() ((void)0)
#define __HAL_RCC_TIM4_FORCE_RESET() ((void)0)
#define __HAL_RCC_TIM4_RELEASE_RESET() ((void)0)
#define __HAL_RCC_TIM5_FORCE_RESET() ((void)0)
#define __HAL_RCC_TIM5_RELEASE_RESET() ((void)0)

static inline uint32_t __get_IPSR(void) { return mock_ipsr; }
static inline uint32_t __get_PRIMASK(void) { return mock_primask; }
static inline void __disable_irq(void) { mock_primask = 1U; }
static inline void __set_PRIMASK(uint32_t mask) { mock_primask = mask; }
static inline uint32_t HAL_RCC_GetPCLK1Freq(void) { return mock_pclk; }
static inline void HAL_Delay(uint32_t ms) { mock_delay += ms; }
static inline void HAL_GPIO_Init(GPIO_TypeDef *port, GPIO_InitTypeDef *gpio)
{ (void)port; (void)gpio; }
static inline void HAL_NVIC_SetPriority(IRQn_Type irq, uint32_t pre, uint32_t sub)
{ (void)irq; (void)pre; (void)sub; }
static inline void HAL_NVIC_ClearPendingIRQ(IRQn_Type irq) { (void)irq; }
static inline void HAL_NVIC_EnableIRQ(IRQn_Type irq) { (void)irq; }
static inline void HAL_IncTick(void) { }

void HAL_TIM_PeriodElapsedCallback(TIM_HandleTypeDef *htim);
static inline void HAL_TIM_IRQHandler(TIM_HandleTypeDef *htim)
{
    if (((htim->Instance->SR & TIM_SR_UIF) != 0U) &&
        ((htim->Instance->DIER & TIM_DIER_UIE) != 0U))
    {
        htim->Instance->SR &= ~TIM_SR_UIF;
        HAL_TIM_PeriodElapsedCallback(htim);
    }
}

#endif
