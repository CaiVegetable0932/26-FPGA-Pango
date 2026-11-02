#include <assert.h>
#include <setjmp.h>
#include <stdio.h>
#include <string.h>
#include "stm32f4xx_hal.h"

/* Stub MCU access and motor commands; exercise the scheduler in actual main.c. */
typedef struct
{
    uint32_t OscillatorType, HSIState, HSICalibrationValue;
    struct { uint32_t PLLState; } PLL;
} RCC_OscInitTypeDef;
typedef struct
{
    uint32_t ClockType, SYSCLKSource, AHBCLKDivider, APB1CLKDivider, APB2CLKDivider;
} RCC_ClkInitTypeDef;

#define __HAL_RCC_PWR_CLK_ENABLE() ((void)0)
#define __HAL_PWR_VOLTAGESCALING_CONFIG(value) ((void)(value))
#define __HAL_RCC_CLEAR_RESET_FLAGS() (mock_rcc.CSR = 0U)
#define PWR_REGULATOR_VOLTAGE_SCALE1 1U
#define RCC_OSCILLATORTYPE_HSI 1U
#define RCC_HSI_ON 1U
#define RCC_HSICALIBRATION_DEFAULT 16U
#define RCC_PLL_NONE 0U
#define RCC_CLOCKTYPE_HCLK 1U
#define RCC_CLOCKTYPE_SYSCLK 2U
#define RCC_CLOCKTYPE_PCLK1 4U
#define RCC_CLOCKTYPE_PCLK2 8U
#define RCC_SYSCLKSOURCE_HSI 1U
#define RCC_SYSCLK_DIV1 1U
#define RCC_HCLK_DIV1 1U
#define FLASH_LATENCY_0 0U

RCC_TypeDef mock_rcc;
uint32_t mock_primask;
static uint32_t tick_base, ticks, init_mask, phase_mask;
static jmp_buf simulation_end;

static void HAL_Init(void) { }
static HAL_StatusTypeDef HAL_RCC_OscConfig(RCC_OscInitTypeDef *config)
{ (void)config; return HAL_OK; }
static HAL_StatusTypeDef HAL_RCC_ClockConfig(RCC_ClkInitTypeDef *config, uint32_t latency)
{ (void)config; (void)latency; return HAL_OK; }
uint32_t HAL_GetTick(void);

#define main firmware_main
#include "../Core/Src/main.c"
#undef main

static struct
{
    uint32_t at_ms, pulses;
    uint8_t motor;
    int16_t rpm;
} commands[16];
static uint32_t command_count;

void MX_GPIO_Init(void) { init_mask |= 1U; }
void MX_TIM2_Init(void) { init_mask |= 2U; }
void MX_TIM3_Init(void) { init_mask |= 4U; }
void MX_TIM4_Init(void) { init_mask |= 8U; }
void MX_TIM5_Init(void) { init_mask |= 16U; }

uint32_t HAL_GetTick(void)
{
    assert(d36a_diagnostic.phase <= 2U);
    phase_mask |= 1U << d36a_diagnostic.phase;
    if (ticks >= 70000U)
    {
        longjmp(simulation_end, 1);
    }
    return tick_base + ticks++;
}

HAL_StatusTypeDef D36A_Control(uint8_t motor, int16_t rpm, uint32_t pulses)
{
    assert(init_mask == 31U);
    assert(command_count < sizeof(commands) / sizeof(commands[0]));
    commands[command_count].at_ms = tick_base + ticks;
    commands[command_count].motor = motor;
    commands[command_count].rpm = rpm;
    commands[command_count].pulses = pulses;
    ++command_count;
    return HAL_OK;
}

static void test_sequence(uint32_t initial_tick)
{
    tick_base = initial_tick;
    ticks = init_mask = phase_mask = command_count = 0U;
    mock_rcc.CSR = 0x0C000000U;
    d36a_diagnostic.uptime_ms = 0U;
    d36a_diagnostic.phase = 0U;
    d36a_diagnostic.phase_elapsed_ms = 0U;
    d36a_diagnostic.commanded_rpm = 0;
    d36a_diagnostic.pulse_commands_per_motor = 0U;
    d36a_diagnostic.moves_started = 0U;
    d36a_diagnostic.error_motor = 0U;
    memset(commands, 0, sizeof(commands));
    if (setjmp(simulation_end) == 0)
    {
        firmware_main();
        assert(0 && "firmware main unexpectedly returned");
    }

    assert(command_count == 13U);
    assert(commands[0].motor == 1U && commands[0].rpm == 0 && commands[0].pulses == 0U);
    for (uint32_t move = 0U; move < 3U; ++move)
    {
        uint32_t first = 1U + move * 4U;
        uint32_t expected_start = 10000U + move * 22000U;
        uint32_t elapsed = (uint32_t)(commands[first].at_ms - tick_base);
        assert(elapsed >= expected_start && elapsed <= expected_start + 4U);
        for (uint32_t motor = 0U; motor < 4U; ++motor)
        {
            uint32_t index = first + motor;
            assert(commands[index].motor == motor + 1U);
            assert(commands[index].rpm == 5);
            assert(commands[index].pulses == 1600U);
            assert(commands[index].at_ms == commands[first].at_ms);
        }
    }
    assert(phase_mask == 7U);
    assert(d36a_diagnostic.phase == 2U);
    assert(d36a_diagnostic.moves_started == 3U);
    assert(d36a_diagnostic.pulse_commands_per_motor == 4800U);
    assert(d36a_diagnostic.reset_csr == 0x0C000000U);
    assert(mock_rcc.CSR == 0U);
    assert(d36a_diagnostic.error_motor == 0U);
}

int main(void)
{
    test_sequence(0U);
    test_sequence(UINT32_MAX - 20000U);
    puts("PASS: actual main startup, repeated forward/hold timing, finite counts and tick wraparound");
    return 0;
}
