#include "d36a_motor.h"

#define D36A_TIMER_HZ       1000000U
#define D36A_MAX_STEP_HZ    3200U
#define D36A_DIRECTION_PINS (GPIO_PIN_0 | GPIO_PIN_1 | GPIO_PIN_2 | GPIO_PIN_3)
#define D36A_ENABLE_PINS    (GPIO_PIN_4 | GPIO_PIN_5 | GPIO_PIN_6 | GPIO_PIN_7)

typedef struct
{
    TIM_TypeDef *timer;
    GPIO_TypeDef *step_port;
    uint16_t step_pin;
    uint16_t direction_pin;
    uint32_t alternate;
    uint32_t channel_shift;
    IRQn_Type irq;
} D36A_Hardware;

typedef struct
{
    uint32_t period;
    uint32_t pulses;
    uint8_t forward;
} D36A_Command;

typedef struct
{
    D36A_Command pending;
    uint32_t remaining;
    uint8_t finite;
    uint8_t running;
    uint8_t pending_valid;
} D36A_State;

static const D36A_Hardware hardware[D36A_MOTOR_COUNT] =
{
    {TIM2, GPIOA, GPIO_PIN_0, GPIO_PIN_0, GPIO_AF1_TIM2, 0U, TIM2_IRQn},
    {TIM3, GPIOA, GPIO_PIN_6, GPIO_PIN_1, GPIO_AF2_TIM3, 0U, TIM3_IRQn},
    {TIM4, GPIOB, GPIO_PIN_6, GPIO_PIN_2, GPIO_AF2_TIM4, 0U, TIM4_IRQn},
    {TIM5, GPIOA, GPIO_PIN_1, GPIO_PIN_3, GPIO_AF2_TIM5, 8U, TIM5_IRQn}
};

static volatile D36A_State state[D36A_MOTOR_COUNT];
static uint8_t initialized;

/* Vector-table entry points, not application interfaces. */
void TIM2_IRQHandler(void);
void TIM3_IRQHandler(void);
void TIM4_IRQHandler(void);
void TIM5_IRQHandler(void);

static void stop_timer(uint32_t index)
{
    TIM_TypeDef *timer = hardware[index].timer;

    timer->CR1 = TIM_CR1_URS | TIM_CR1_ARPE;
    timer->DIER = 0U;
    /* Forced inactive keeps STEP low even while changing ARR/CCR. */
    timer->CCMR1 = TIM_CCMR1_OC1M_2 << hardware[index].channel_shift;
    timer->CNT = 0U;
    timer->SR = 0U;
    state[index].running = 0U;
    state[index].remaining = 0U;
    state[index].finite = 0U;
}

static void apply_command(uint32_t index, const D36A_Command *command)
{
    const D36A_Hardware *pins = &hardware[index];
    TIM_TypeDef *timer = pins->timer;

    stop_timer(index);
    if (command->period == 0U)
    {
        return;
    }

    GPIOC->BSRR = command->forward ? pins->direction_pin :
                  ((uint32_t)pins->direction_pin << 16U);
    timer->ARR = command->period - 1U;
    if (pins->channel_shift == 0U)
    {
        timer->CCR1 = (command->period + 1U) / 2U;
    }
    else
    {
        timer->CCR2 = (command->period + 1U) / 2U;
    }

    /* PWM2: low first, then high, then a falling edge at the update interrupt.
     * Count completed pulses at that falling edge, leaving half a period to
     * stop before another rising edge. The initial low half also sets up DIR.
     */
    timer->EGR = TIM_EGR_UG;
    timer->SR = 0U;
    timer->CCMR1 = (TIM_CCMR1_OC1M | TIM_CCMR1_OC1PE) << pins->channel_shift;
    state[index].remaining = command->pulses;
    state[index].finite = (command->pulses != 0U);
    state[index].running = 1U;
    timer->DIER = TIM_DIER_UIE;
    timer->CR1 |= TIM_CR1_CEN;
}

static HAL_StatusTypeDef initialize(void)
{
    GPIO_InitTypeDef gpio = {0};
    uint32_t timer_clock = HAL_RCC_GetPCLK1Freq();

    if ((RCC->CFGR & RCC_CFGR_PPRE1) != 0U)
    {
        timer_clock *= 2U;
    }
    if ((timer_clock < D36A_TIMER_HZ) ||
        ((timer_clock % D36A_TIMER_HZ) != 0U) ||
        ((timer_clock / D36A_TIMER_HZ) > 65536U))
    {
        return HAL_ERROR;
    }

    __HAL_RCC_GPIOA_CLK_ENABLE();
    __HAL_RCC_GPIOB_CLK_ENABLE();
    __HAL_RCC_GPIOC_CLK_ENABLE();
    __HAL_RCC_TIM2_CLK_ENABLE();
    __HAL_RCC_TIM3_CLK_ENABLE();
    __HAL_RCC_TIM4_CLK_ENABLE();
    __HAL_RCC_TIM5_CLK_ENABLE();
    __HAL_RCC_TIM2_FORCE_RESET();
    __HAL_RCC_TIM2_RELEASE_RESET();
    __HAL_RCC_TIM3_FORCE_RESET();
    __HAL_RCC_TIM3_RELEASE_RESET();
    __HAL_RCC_TIM4_FORCE_RESET();
    __HAL_RCC_TIM4_RELEASE_RESET();
    __HAL_RCC_TIM5_FORCE_RESET();
    __HAL_RCC_TIM5_RELEASE_RESET();

    GPIOC->BSRR = (uint32_t)(D36A_DIRECTION_PINS | D36A_ENABLE_PINS) << 16U;
    gpio.Pin = D36A_DIRECTION_PINS | D36A_ENABLE_PINS;
    gpio.Mode = GPIO_MODE_OUTPUT_PP;
    gpio.Pull = GPIO_PULLDOWN;
    gpio.Speed = GPIO_SPEED_FREQ_LOW;
    HAL_GPIO_Init(GPIOC, &gpio);

    /* Freeze PWM along with the CPU so debugging cannot produce extra steps. */
    DBGMCU->APB1FZ |= DBGMCU_APB1_FZ_DBG_TIM2_STOP |
                      DBGMCU_APB1_FZ_DBG_TIM3_STOP |
                      DBGMCU_APB1_FZ_DBG_TIM4_STOP |
                      DBGMCU_APB1_FZ_DBG_TIM5_STOP;

    for (uint32_t index = 0U; index < D36A_MOTOR_COUNT; ++index)
    {
        const D36A_Hardware *pins = &hardware[index];
        TIM_TypeDef *timer = pins->timer;

        stop_timer(index);
        timer->PSC = timer_clock / D36A_TIMER_HZ - 1U;
        timer->ARR = 65535U;
        timer->EGR = TIM_EGR_UG;
        timer->SR = 0U;
        timer->CCER = (pins->channel_shift == 0U) ? TIM_CCER_CC1E : TIM_CCER_CC2E;

        gpio.Pin = pins->step_pin;
        gpio.Mode = GPIO_MODE_AF_PP;
        gpio.Alternate = pins->alternate;
        HAL_GPIO_Init(pins->step_port, &gpio);

        HAL_NVIC_SetPriority(pins->irq, 1U, 0U);
        HAL_NVIC_ClearPendingIRQ(pins->irq);
        HAL_NVIC_EnableIRQ(pins->irq);
    }

    /* D36A EN goes to nSLEEP, not the chip's active-low nENABLE pin. */
    GPIOC->BSRR = D36A_ENABLE_PINS;
    HAL_Delay(2U);
    initialized = 1U;
    return HAL_OK;
}

HAL_StatusTypeDef D36A_Control(uint8_t motor, int16_t rpm, uint32_t pulses)
{
    D36A_Command command = {0};
    uint32_t index;
    uint32_t interrupt_mask;

    if ((motor < 1U) || (motor > D36A_MOTOR_COUNT) ||
        (rpm < -D36A_MAX_RPM) || (rpm > D36A_MAX_RPM) ||
        (__get_IPSR() != 0U) || (__get_PRIMASK() != 0U))
    {
        return HAL_ERROR;
    }

    if (rpm != 0)
    {
        uint32_t speed = (rpm > 0) ? (uint32_t)rpm : (uint32_t)(-rpm);
        uint64_t steps_per_minute = (uint64_t)D36A_PULSES_PER_REV * speed;
        uint64_t period;

        if ((steps_per_minute == 0U) ||
            (steps_per_minute > (uint64_t)D36A_MAX_STEP_HZ * 60U))
        {
            return HAL_ERROR;
        }
        period = ((uint64_t)D36A_TIMER_HZ * 60U + steps_per_minute / 2U) /
                 steps_per_minute;
        if ((period < 2U) || (period > 65536U))
        {
            return HAL_ERROR;
        }
        command.period = (uint32_t)period;
        command.pulses = pulses;
        command.forward = (rpm > 0);
    }

    if ((initialized == 0U) && (initialize() != HAL_OK))
    {
        return HAL_ERROR;
    }

    index = (uint32_t)motor - 1U;
    interrupt_mask = __get_PRIMASK();
    __disable_irq();
    if (state[index].running != 0U)
    {
        state[index].pending = command;
        state[index].pending_valid = 1U;
    }
    else
    {
        state[index].pending_valid = 0U;
        apply_command(index, &command);
    }
    __set_PRIMASK(interrupt_mask);
    return HAL_OK;
}

static void handle_update(uint32_t index)
{
    TIM_TypeDef *timer = hardware[index].timer;

    if (((timer->SR & TIM_SR_UIF) == 0U) || ((timer->DIER & TIM_DIER_UIE) == 0U))
    {
        return;
    }
    timer->SR = ~TIM_SR_UIF;

    if (state[index].pending_valid != 0U)
    {
        D36A_Command command = state[index].pending;

        state[index].pending_valid = 0U;
        apply_command(index, &command);
    }
    else if (state[index].finite != 0U)
    {
        --state[index].remaining;
        if (state[index].remaining == 0U)
        {
            stop_timer(index);
        }
    }
}

void TIM2_IRQHandler(void)
{
    handle_update(0U);
}

void TIM3_IRQHandler(void)
{
    handle_update(1U);
}

void TIM4_IRQHandler(void)
{
    handle_update(2U);
}

void TIM5_IRQHandler(void)
{
    handle_update(3U);
}
