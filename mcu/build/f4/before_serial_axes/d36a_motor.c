#include "d36a_motor.h"
#include "main.h"
#include "tim.h"

#define D36A_TIMER_HZ       1000000U
#define D36A_MAX_STEP_HZ    3200U

typedef struct
{
    TIM_HandleTypeDef *handle;
    GPIO_TypeDef *direction_port;
    uint16_t direction_pin;
    GPIO_TypeDef *enable_port;
    uint16_t enable_pin;
    uint32_t channel_shift;
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
    {&htim2, D36A_M1_DIR_GPIO_Port, D36A_M1_DIR_Pin,
     D36A_M1_EN_GPIO_Port, D36A_M1_EN_Pin, 0U},
    {&htim5, D36A_M2_DIR_GPIO_Port, D36A_M2_DIR_Pin,
     D36A_M2_EN_GPIO_Port, D36A_M2_EN_Pin, 8U},
    {&htim3, D36A_M3_DIR_GPIO_Port, D36A_M3_DIR_Pin,
     D36A_M3_EN_GPIO_Port, D36A_M3_EN_Pin, 0U},
    {&htim4, D36A_M4_DIR_GPIO_Port, D36A_M4_DIR_Pin,
     D36A_M4_EN_GPIO_Port, D36A_M4_EN_Pin, 0U}
};

static volatile D36A_State state[D36A_MOTOR_COUNT];
static uint8_t initialized;

static void stop_timer(uint32_t index)
{
    TIM_TypeDef *timer = hardware[index].handle->Instance;

    timer->CR1 &= ~TIM_CR1_CEN;
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
    TIM_TypeDef *timer = pins->handle->Instance;

    stop_timer(index);
    if (command->period == 0U)
    {
        return;
    }

    pins->direction_port->BSRR = command->forward ? pins->direction_pin :
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

    /* CubeMX owns clocks, GPIO, PWM setup and NVIC. Reject a missing init or
     * incompatible prescaler instead of silently overriding the .ioc settings.
     */
    for (uint32_t index = 0U; index < D36A_MOTOR_COUNT; ++index)
    {
        TIM_HandleTypeDef *handle = hardware[index].handle;

        if ((handle->Instance == NULL) || (handle->State != HAL_TIM_STATE_READY) ||
            (handle->Instance->PSC != timer_clock / D36A_TIMER_HZ - 1U))
        {
            return HAL_ERROR;
        }
    }

    /* Freeze PWM along with the CPU so debugging cannot produce extra steps. */
    DBGMCU->APB1FZ |= DBGMCU_APB1_FZ_DBG_TIM2_STOP |
                      DBGMCU_APB1_FZ_DBG_TIM3_STOP |
                      DBGMCU_APB1_FZ_DBG_TIM4_STOP |
                      DBGMCU_APB1_FZ_DBG_TIM5_STOP;

    for (uint32_t index = 0U; index < D36A_MOTOR_COUNT; ++index)
    {
        const D36A_Hardware *pins = &hardware[index];
        TIM_TypeDef *timer = pins->handle->Instance;

        stop_timer(index);
        /* Software UG loads new speed without creating a counted interrupt. */
        timer->CR1 |= TIM_CR1_URS;
        timer->CCER = (pins->channel_shift == 0U) ? TIM_CCER_CC1E : TIM_CCER_CC2E;
    }

    /* D36A EN goes to nSLEEP, not the chip's active-low nENABLE pin. */
    for (uint32_t index = 0U; index < D36A_MOTOR_COUNT; ++index)
    {
        hardware[index].enable_port->BSRR = hardware[index].enable_pin;
    }
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
    if (state[index].running == 0U)
    {
        return;
    }

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

/* CubeMX's IRQ handlers clear UIF through HAL before reaching this callback. */
void HAL_TIM_PeriodElapsedCallback(TIM_HandleTypeDef *htim)
{
    for (uint32_t index = 0U; index < D36A_MOTOR_COUNT; ++index)
    {
        if (htim == hardware[index].handle)
        {
            handle_update(index);
            return;
        }
    }
}
