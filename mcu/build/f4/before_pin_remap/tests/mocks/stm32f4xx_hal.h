#ifndef TEST_STM32F4XX_HAL_H
#define TEST_STM32F4XX_HAL_H

#include <stdint.h>
#include <stddef.h>

typedef enum { HAL_OK, HAL_ERROR } HAL_StatusTypeDef;
typedef enum { TIM2_IRQn, TIM3_IRQn, TIM4_IRQn, TIM5_IRQn } IRQn_Type;
typedef struct
{
    uint32_t CR1, DIER, CCMR1, CNT, SR, ARR, CCR1, CCR2, EGR, PSC, CCER;
} TIM_TypeDef;
typedef enum { HAL_TIM_STATE_RESET, HAL_TIM_STATE_READY } HAL_TIM_StateTypeDef;
typedef struct { TIM_TypeDef *Instance; HAL_TIM_StateTypeDef State; } TIM_HandleTypeDef;
typedef struct { uint32_t BSRR; } GPIO_TypeDef;
typedef struct { uint32_t CFGR; } RCC_TypeDef;
typedef struct { uint32_t APB1FZ; } DBGMCU_TypeDef;
typedef struct { uint32_t Pin, Mode, Pull, Speed, Alternate; } GPIO_InitTypeDef;

extern TIM_TypeDef mock_timers[4];
extern GPIO_TypeDef mock_gpio[3];
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
