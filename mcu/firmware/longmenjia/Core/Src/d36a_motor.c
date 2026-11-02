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
    uint8_t forward;
    int32_t position;
} D36A_State;

/* 2026-10-22：现场把两块 D36A 驱动板接反（**板内通道对应正确**，只是两块板互换）。
 * 为避免重新接线，这里按实际接线重排"电机编号 -> 引脚组/定时器"的对应关系：
 *   电机 1（X，单电机）   ← M2 信号组  TIM5_CH2  PA1 STEP / PA2 DIR / PC3 EN
 *   电机 2（龙门架 A）    ← M1 信号组  TIM2_CH1  PA5 STEP / PA4 DIR / PC2 EN
 *   电机 3（龙门架 B）    ← M4 信号组  TIM4_CH1  PB6 STEP / PB11 DIR / PB10 EN
 *   电机 4（Y，单电机）   ← M3 信号组  TIM3_CH1  PA6 STEP / PB5 DIR / PG8 EN
 * 龙门架仍是 index1+index2，因此同步关系从"TIM3 主 + TIM5 从"整体搬到"TIM2 主 + TIM4 从"
 * （TIM4 的 ITR1 正是 TIM2，可与原方案等价地做门控同步）。 */
static const D36A_Hardware hardware[D36A_MOTOR_COUNT] =
{
    {&htim5, D36A_M2_DIR_GPIO_Port, D36A_M2_DIR_Pin,
     D36A_M2_EN_GPIO_Port, D36A_M2_EN_Pin, 8U},
    {&htim2, D36A_M1_DIR_GPIO_Port, D36A_M1_DIR_Pin,
     D36A_M1_EN_GPIO_Port, D36A_M1_EN_Pin, 0U},
    {&htim4, D36A_M4_DIR_GPIO_Port, D36A_M4_DIR_Pin,
     D36A_M4_EN_GPIO_Port, D36A_M4_EN_Pin, 0U},
    {&htim3, D36A_M3_DIR_GPIO_Port, D36A_M3_DIR_Pin,
     D36A_M3_EN_GPIO_Port, D36A_M3_EN_Pin, 0U}
};

static volatile D36A_State state[D36A_MOTOR_COUNT];
static uint8_t initialized;
static uint8_t gantry_enabled;

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

static void prepare_command(uint32_t index, const D36A_Command *command)
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
    state[index].forward = command->forward;
    timer->DIER = TIM_DIER_UIE;
}

static void apply_command(uint32_t index, const D36A_Command *command)
{
    if (index == 0U)
    {
        /* 电机 1 现在由 TIM5 驱动；TIM5 在 .ioc 里配的是门控从模式（原用于龙门架），
         * 单轴独立运动必须先清掉从模式，否则主定时器不跑就没有脉冲。 */
        TIM5->SMCR &= ~(TIM_SMCR_SMS | TIM_SMCR_TS);
    }
    else if (index == 2U)
    {
        /* 电机 3（TIM4）平时作为龙门架从机，若被单独驱动同样要脱离门控。 */
        TIM4->SMCR &= ~(TIM_SMCR_SMS | TIM_SMCR_TS);
    }
    prepare_command(index, command);
    if (command->period != 0U)
    {
        hardware[index].handle->Instance->CR1 |= TIM_CR1_CEN;
    }
}

static void apply_gantry(const D36A_Command *command)
{
    D36A_Command reverse = *command;
    reverse.forward = !command->forward;
    /* 2026-10-22：龙门架改为 TIM2(主) 门控 TIM4(从)。TIM4 的 ITR1 = TIM2。
     * 先武装从定时器，再同时启动两者，保证两台电机严格同步起停。 */
    stop_timer(2U);
    stop_timer(1U);
    TIM4->SMCR = (TIM4->SMCR & ~(TIM_SMCR_SMS | TIM_SMCR_TS)) |
                 TIM_SLAVEMODE_GATED | TIM_TS_ITR1;
    prepare_command(1U, command);
    prepare_command(2U, &reverse);
    /* 2026-10-22：脉冲计数与状态机仍挂在 index2（现在是从机 TIM4）上：
     * handle_update() 只在 index==2 分支做龙门架计数/镜像/收尾，D36A_GetStatus 也读 state[2]。
     * 因此关闭的是主定时器 TIM2 的更新中断，TIM4 的 UIE 必须保留。 */
    TIM2->DIER = 0U;
    if (command->period != 0U)
    {
        TIM4->CR1 |= TIM_CR1_CEN;
        TIM2->CR1 |= TIM_CR1_CEN;
    }
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

    /* 主/从关系由 FPGA.ioc 决定（2026-10-22）：
     *   TIM2 = 龙门架主（TIM_MasterOutputTrigger = TRGO_ENABLE）
     *   TIM4 = 龙门架从（TIM_SlaveMode = GATED，TIM_InputTrigger = ITR1，即 TIM2）
     *   TIM3 / TIM5 = 独立单轴（不设从模式、TRGO 为 RESET）
     * 这里不再运行时改写 CR2/SMCR，避免与 .ioc 冲突；apply_gantry() 每次命令前
     * 会重新武装从机，属于逐命令的时序要求，不改变静态配置。 */

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

    if ((motor < 1U) || (motor > D36A_GANTRY) ||
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

    if (rpm != 0)
    {
        D36A_Status current;
        if (D36A_GetStatus(motor, &current) != HAL_OK)
        {
            return HAL_ERROR;
        }
        int64_t target = (int64_t)current.position + ((rpm > 0) ? (int64_t)pulses : -(int64_t)pulses);
        if ((target > INT32_MAX) || (target < -INT32_MAX) ||
            ((rpm > 0) && current.position == INT32_MAX) ||
            ((rpm < 0) && current.position == -INT32_MAX))
        {
            return HAL_ERROR;
        }
    }

    if (motor == D36A_GANTRY)
    {
        if (((TIM2->CR2 & TIM_CR2_MMS) != TIM_TRGO_ENABLE) ||
            ((gantry_enabled == 0U) && (state[1].running || state[2].running ||
                                      state[1].position != 0 || state[2].position != 0)))
        {
            return HAL_ERROR;
        }
        gantry_enabled = 1U;
        interrupt_mask = __get_PRIMASK();
        __disable_irq();
        if (state[2].running != 0U)
        {
            state[2].pending = command;
            state[2].pending_valid = 1U;
        }
        else
        {
            state[2].pending_valid = 0U;
            apply_gantry(&command);
        }
        __set_PRIMASK(interrupt_mask);
        return HAL_OK;
    }
    index = (uint32_t)motor - 1U;
    if (gantry_enabled && ((index == 1U) || (index == 2U)))
    {
        return HAL_ERROR;
    }
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

    state[index].position += state[index].forward ? 1 : -1;
    if (gantry_enabled && (index == 2U))
    {
        state[1].position = -state[2].position;
        if ((state[index].position == INT32_MAX) || (state[index].position == -INT32_MAX))
        {
            D36A_Command stop = {0};
            state[index].pending_valid = 0U;
            apply_gantry(&stop);
        }
        else if (state[index].pending_valid)
        {
            D36A_Command command = state[index].pending;
            state[index].pending_valid = 0U;
            apply_gantry(&command);
        }
        else if (state[index].finite && (--state[index].remaining == 0U))
        {
            D36A_Command stop = {0};
            apply_gantry(&stop);
        }
        return;
    }
    if ((state[index].position == INT32_MAX) || (state[index].position == -INT32_MAX))
    {
        state[index].pending_valid = 0U;
        stop_timer(index);
    }
    else if (state[index].pending_valid != 0U)
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

HAL_StatusTypeDef D36A_GetStatus(uint8_t motor, D36A_Status *status)
{
    uint32_t index;
    uint32_t mask;
    int64_t position;
    if ((status == NULL) || (motor < 1U) || (motor > D36A_GANTRY) || !initialized)
    {
        return HAL_ERROR;
    }
    index = (motor == D36A_GANTRY) ? 2U : (uint32_t)motor - 1U;
    if (gantry_enabled && (index == 1U))
    {
        index = 2U;
    }
    mask = __get_PRIMASK();
    __disable_irq();
    TIM_TypeDef *timer = hardware[index].handle->Instance;
    position = state[index].position;
    if (state[index].running)
    {
        uint32_t before, after, counter;
        do
        {
            before = timer->SR & TIM_SR_UIF;
            counter = timer->CNT;
            after = timer->SR & TIM_SR_UIF;
        } while (before != after);
        uint32_t compare = (index == 1U) ? timer->CCR2 : timer->CCR1;
        uint32_t uncounted = (after != 0U) + (counter >= compare);
        position += state[index].forward ? (int32_t)uncounted : -(int32_t)uncounted;
    }
    if (position > INT32_MAX) position = INT32_MAX;
    if (position < -INT32_MAX) position = -INT32_MAX;
    status->position = (int32_t)(((motor == D36A_GANTRY) || (gantry_enabled && motor == 2U)) ?
                       -position : position);
    status->running = state[index].running;
    __set_PRIMASK(mask);
    return HAL_OK;
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
