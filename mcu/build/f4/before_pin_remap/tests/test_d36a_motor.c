#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "stm32f4xx_hal.h"

TIM_TypeDef mock_timers[4];
GPIO_TypeDef mock_gpio[3];
RCC_TypeDef mock_rcc;
DBGMCU_TypeDef mock_debug;
uint32_t mock_primask, mock_ipsr, mock_delay;
uint32_t mock_pclk = 16000000U;
TIM_HandleTypeDef htim2, htim3, htim4, htim5;

#include "../Core/Src/d36a_motor.c"
#include "../Core/Src/stm32f4xx_it.c"

static void (*const interrupts[4])(void) =
{
    TIM2_IRQHandler, TIM3_IRQHandler, TIM4_IRQHandler, TIM5_IRQHandler
};
static uint32_t rising_edges[4];

static void reset_fixture(void)
{
    memset(mock_timers, 0, sizeof(mock_timers));
    memset(mock_gpio, 0, sizeof(mock_gpio));
    memset((void *)state, 0, sizeof(state));
    memset(rising_edges, 0, sizeof(rising_edges));
    mock_rcc.CFGR = 0U;
    mock_debug.APB1FZ = 0U;
    mock_primask = mock_ipsr = mock_delay = 0U;
    mock_pclk = 16000000U;
    initialized = 0U;
    htim2 = (TIM_HandleTypeDef){TIM2, HAL_TIM_STATE_READY};
    htim3 = (TIM_HandleTypeDef){TIM3, HAL_TIM_STATE_READY};
    htim4 = (TIM_HandleTypeDef){TIM4, HAL_TIM_STATE_READY};
    htim5 = (TIM_HandleTypeDef){TIM5, HAL_TIM_STATE_READY};
    for (uint32_t index = 0U; index < 4U; ++index)
    {
        mock_timers[index].PSC = 15U;
        mock_timers[index].ARR = 65535U;
        mock_timers[index].CR1 = TIM_CR1_ARPE;
    }
}

/* Advance the PWM counter at 1 MHz and dispatch update IRQs at rollover.
 * This validates generated pulse counts and timing, not MCU interrupt latency.
 */
static void advance(uint32_t microseconds)
{
    for (uint32_t time = 0U; time < microseconds; ++time)
    {
        for (uint32_t index = 0U; index < 4U; ++index)
        {
            TIM_TypeDef *timer = &mock_timers[index];
            uint32_t compare = (index == 3U) ? timer->CCR2 : timer->CCR1;
            uint32_t shift = (index == 3U) ? 8U : 0U;

            if ((timer->CR1 & TIM_CR1_CEN) == 0U)
            {
                continue;
            }
            ++timer->CNT;
            if (timer->CNT > timer->ARR)
            {
                timer->CNT = 0U;
                timer->SR |= TIM_SR_UIF;
                if ((timer->DIER & TIM_DIER_UIE) != 0U)
                {
                    interrupts[index]();
                }
            }
            else if (timer->CNT == compare)
            {
                assert(((timer->CCMR1 >> shift) & TIM_CCMR1_OC1M) == TIM_CCMR1_OC1M);
                ++rising_edges[index];
            }
        }
    }
}

static void test_four_revolutions(void)
{
    reset_fixture();
    for (uint8_t motor = 1U; motor <= 4U; ++motor)
    {
        assert(D36A_Control(motor, 10, D36A_PULSES_PER_REV) == HAL_OK);
        assert(mock_timers[motor - 1U].PSC == 15U);
        assert(mock_timers[motor - 1U].ARR == 3749U);
    }
    assert(mock_delay == 2U);
    assert(mock_debug.APB1FZ == 15U);
    advance(6000000U);
    for (uint32_t index = 0U; index < 4U; ++index)
    {
        assert(rising_edges[index] == 1600U);
        assert((mock_timers[index].CR1 & TIM_CR1_CEN) == 0U);
        assert(mock_timers[index].DIER == 0U);
    }
    advance(4000000U);
    assert(rising_edges[0] == 1600U);
    assert(D36A_Control(1U, 10, D36A_PULSES_PER_REV) == HAL_OK);
    advance(6000000U);
    assert(rising_edges[0] == 3200U);
    assert(rising_edges[1] == 1600U);
}

static void test_independent_speed_direction_and_one_pulse(void)
{
    reset_fixture();
    assert(D36A_Control(1U, 10, 0U) == HAL_OK);
    assert(D36A_Control(2U, -20, 0U) == HAL_OK);
    assert(GPIOC->BSRR == (GPIO_PIN_1 << 16U));
    assert(D36A_Control(3U, 1, 1U) == HAL_OK);
    assert(D36A_Control(4U, -60, 0U) == HAL_OK);
    advance(375000U);
    assert(rising_edges[0] == 100U);
    assert(rising_edges[1] == 200U);
    assert(rising_edges[2] == 1U);
    assert(rising_edges[3] == 600U);
    assert((TIM4->CR1 & TIM_CR1_CEN) == 0U);
    assert((TIM5->CCER & TIM_CCER_CC2E) != 0U);
}

static void test_reversal_and_stop_finish_current_pulse(void)
{
    reset_fixture();
    assert(D36A_Control(1U, 10, 0U) == HAL_OK);
    advance(2000U);
    assert(rising_edges[0] == 1U);
    assert(D36A_Control(1U, -20, 1U) == HAL_OK);
    assert(GPIOC->BSRR == GPIO_PIN_0);
    assert(TIM2->ARR == 3749U);
    advance(1750U);
    assert(GPIOC->BSRR == (GPIO_PIN_0 << 16U));
    assert(TIM2->ARR == 1874U);
    advance(1875U);
    assert(rising_edges[0] == 2U);
    assert((TIM2->CR1 & TIM_CR1_CEN) == 0U);

    assert(D36A_Control(1U, 10, 0U) == HAL_OK);
    advance(2000U);
    assert(D36A_Control(1U, 0, 0U) == HAL_OK);
    assert((TIM2->CR1 & TIM_CR1_CEN) != 0U);
    advance(1750U);
    assert((TIM2->CR1 & TIM_CR1_CEN) == 0U);
    advance(10000U);
    assert(rising_edges[0] == 3U);
}

static void test_last_pending_command_wins(void)
{
    reset_fixture();
    assert(D36A_Control(4U, 10, 1U) == HAL_OK);
    assert(D36A_Control(4U, 20, 3U) == HAL_OK);
    assert(D36A_Control(4U, -60, 2U) == HAL_OK);
    advance(5000U);
    assert(rising_edges[3] == 3U);
    assert((TIM5->CR1 & TIM_CR1_CEN) == 0U);
    assert(GPIOC->BSRR == (GPIO_PIN_3 << 16U));
}

static void test_validation_and_clock(void)
{
    reset_fixture();
    assert(D36A_Control(0U, 10, 0U) == HAL_ERROR);
    assert(D36A_Control(5U, 10, 0U) == HAL_ERROR);
    assert(D36A_Control(1U, 61, 0U) == HAL_ERROR);
    assert(D36A_Control(1U, -32768, 0U) == HAL_ERROR);
    mock_ipsr = 1U;
    assert(D36A_Control(1U, 10, 0U) == HAL_ERROR);
    mock_ipsr = 0U;
    mock_primask = 1U;
    assert(D36A_Control(1U, 10, 0U) == HAL_ERROR);
    mock_primask = 0U;
    mock_pclk = 15500000U;
    assert(D36A_Control(1U, 10, 0U) == HAL_ERROR);
    assert(mock_delay == 0U);
    mock_pclk = 42000000U;
    mock_rcc.CFGR = 0x1400U;
    assert(D36A_Control(1U, 0, 0U) == HAL_ERROR);
    assert(TIM2->PSC == 15U);
    assert(mock_delay == 0U);
    for (uint32_t index = 0U; index < 4U; ++index)
    {
        mock_timers[index].PSC = 83U;
    }
    assert(D36A_Control(1U, 0, 0U) == HAL_OK);
    assert(TIM2->PSC == 83U);
    assert((TIM2->CR1 & TIM_CR1_CEN) == 0U);
    assert(GPIOC->BSRR == D36A_M4_EN_Pin);
    assert(D36A_Control(1U, 1, UINT32_MAX) == HAL_OK);
    assert(D36A_Control(1U, -61, 0U) == HAL_ERROR);
    advance(37500U);
    assert(rising_edges[0] == 1U);
    assert((TIM2->CR1 & TIM_CR1_CEN) != 0U);
    assert(mock_primask == 0U);
}

static void test_missing_init_and_unrelated_callback(void)
{
    reset_fixture();
    htim5.Instance = NULL;
    assert(D36A_Control(1U, 10, 1600U) == HAL_ERROR);
    assert(mock_delay == 0U);
    assert(GPIOC->BSRR == 0U);
    htim5.Instance = TIM5;
    htim3.State = HAL_TIM_STATE_RESET;
    assert(D36A_Control(1U, 10, 1600U) == HAL_ERROR);
    htim3.State = HAL_TIM_STATE_READY;
    assert(D36A_Control(1U, 10, 1U) == HAL_OK);
    TIM_HandleTypeDef unrelated = {TIM2, HAL_TIM_STATE_READY};
    HAL_TIM_PeriodElapsedCallback(&unrelated);
    assert(state[0].remaining == 1U);
    TIM2_IRQHandler(); /* No UIF: a spurious vector entry must not count. */
    assert(state[0].remaining == 1U);
    advance(3750U);
    assert(rising_edges[0] == 1U);
    assert((TIM2->CR1 & TIM_CR1_CEN) == 0U);
}

int main(void)
{
    test_four_revolutions();
    test_independent_speed_direction_and_one_pulse();
    test_reversal_and_stop_finish_current_pulse();
    test_last_pending_command_wins();
    test_validation_and_clock();
    test_missing_init_and_unrelated_callback();
    puts("PASS: pulse counts, speeds, direction, stop, CubeMX IRQ dispatch and init/clock validation");
    return 0;
}
