/* Host-side protocol test for the generated firmware and the real motor driver. */
#include <assert.h>
#include <setjmp.h>
#include <stdio.h>
#include <string.h>

#define main driver_regression_main
#include "test_d36a_motor.c"
#undef main

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
static void HAL_Init(void) { }
static HAL_StatusTypeDef HAL_RCC_OscConfig(RCC_OscInitTypeDef *config)
{ (void)config; return HAL_OK; }
static HAL_StatusTypeDef HAL_RCC_ClockConfig(RCC_ClkInitTypeDef *config, uint32_t latency)
{ (void)config; (void)latency; return HAL_OK; }

#define main firmware_main
#include "../../firmware/longmenjia/Core/Src/main.c"
#undef main

static char transmitted[8192];
static size_t transmitted_size;
static uint8_t *receive_target;
static uint32_t init_mask;
static uint8_t booting;
static uint32_t boot_reply_count;
static uint32_t receive_failures;
static jmp_buf boot_complete;
static USART_TypeDef mock_uart;

void MX_GPIO_Init(void) { init_mask |= 1U; }
void MX_TIM2_Init(void) { init_mask |= 2U; }
void MX_TIM3_Init(void) { init_mask |= 4U; }
void MX_TIM4_Init(void) { init_mask |= 8U; }
void MX_TIM5_Init(void) { init_mask |= 16U; }
void MX_USART3_UART_Init(void)
{
    init_mask |= 32U;
    huart3.Instance = &mock_uart;
    huart3.RxState = HAL_UART_STATE_READY;
    huart3.ErrorCode = HAL_UART_ERROR_NONE;
}

HAL_StatusTypeDef HAL_UART_Receive_IT(UART_HandleTypeDef *uart, uint8_t *data, uint16_t size)
{
    assert(uart == &huart3 && size == 1U);
    if (receive_failures) { --receive_failures; return HAL_ERROR; }
    if (uart->RxState != HAL_UART_STATE_READY) return HAL_BUSY;
    uart->ErrorCode = HAL_UART_ERROR_NONE;
    uart->RxState = HAL_UART_STATE_BUSY_RX;
    uart->Instance->CR1 |= UART_IT_RXNE;
    uart->Instance->CR3 |= UART_IT_ERR;
    receive_target = data;
    return HAL_OK;
}
HAL_StatusTypeDef HAL_UART_AbortReceive(UART_HandleTypeDef *uart)
{
    assert(uart == &huart3);
    receive_target = NULL;
    uart->RxState = HAL_UART_STATE_READY;
    uart->Instance->CR1 &= ~(UART_IT_RXNE | UART_IT_PE);
    uart->Instance->CR3 &= ~UART_IT_ERR;
    return HAL_OK;
}
HAL_StatusTypeDef HAL_UART_Abort(UART_HandleTypeDef *uart)
{
    uart->ErrorCode = HAL_UART_ERROR_NONE;
    return HAL_UART_AbortReceive(uart);
}
HAL_StatusTypeDef HAL_UART_Transmit(UART_HandleTypeDef *uart, uint8_t *data,
                                    uint16_t size, uint32_t timeout)
{
    assert(uart == &huart3 && timeout == 100U);
    assert(transmitted_size + size < sizeof(transmitted));
    memcpy(transmitted + transmitted_size, data, size);
    transmitted_size += size;
    transmitted[transmitted_size] = '\0';
    if (booting)
    {
        if (boot_reply_count == 0U)
        {
            assert(!axes[0].configured && !axes[1].configured && !axes[2].configured);
        }
        if (++boot_reply_count == 3U) longjmp(boot_complete, 1);
    }
    return HAL_OK;
}

static void clear_output(void) { transmitted_size = 0U; transmitted[0] = '\0'; }
static void receive(const char *text)
{
    while (*text)
    {
        uint8_t ch = (uint8_t)*text++;
        if (huart3.RxState != HAL_UART_STATE_BUSY_RX ||
            !(mock_uart.CR1 & UART_IT_RXNE))
        {
            mock_uart.SR |= USART_SR_RXNE;
            mock_uart.DR = ch;
            continue;
        }
        assert(receive_target != NULL);
        *receive_target = ch;
        huart3.RxState = HAL_UART_STATE_READY;
        mock_uart.CR1 &= ~(UART_IT_RXNE | UART_IT_PE);
        mock_uart.CR3 &= ~UART_IT_ERR;
        HAL_UART_RxCpltCallback(&huart3);
    }
}
static void send(const char *text)
{
    clear_output();
    receive(text);
    serial_poll();
    motion_poll();
}
static void expect(const char *text)
{
    if (strcmp(transmitted, text) != 0)
    {
        fprintf(stderr, "Expected [%s], got [%s]\n", text, transmitted);
        assert(0);
    }
}
static void boot(void)
{
    reset_fixture();
    memset(axes, 0, sizeof(axes));
    rx_head = rx_tail = rx_fault = discard_line = 0U;
    command_length = 0U;
    init_mask = 0U;
    clear_output();
    booting = 1U;
    boot_reply_count = 0U;
    receive_failures = 0U;
    mock_uart = (USART_TypeDef){0};
    receive_target = NULL;
    if (setjmp(boot_complete) == 0) firmware_main();
    booting = 0U;
    expect("ready\r\nok set 1 5.696250\r\nok set 2 6.195625\r\n");
    assert(init_mask == 63U && gantry_enabled);
    assert(axes[0].configured && axes[0].limit == 9114U);
    assert(axes[1].configured && axes[1].limit == 9913U);
    assert(!axes[2].configured && axes[2].limit == 0U);
    for (uint32_t i = 0U; i < AXIS_COUNT; ++i)
        assert(axis_status(i).position == 0 && !axis_status(i).running);
    for (uint32_t i = 0U; i < D36A_MOTOR_COUNT; ++i) assert(rising_edges[i] == 0U);
}

static void test_measured_startup_travel_and_wake(void)
{
    boot();
    send("state\n"); expect("state 0.000000 0.000000 0.000000\r\n");
    send("out 1 10\n"); expect("error not_set 3\r\n");
    send("go 100 100 60\n"); expect("ok go 100.000000 100.000000 60\r\n");
    advance(6195625U);
    clear_output(); motion_poll();
    expect("done 1 100.000000\r\ndone 2 100.000000\r\n");
    assert(rising_edges[0] == 9114U && rising_edges[1] == 9913U &&
           rising_edges[3] == 9913U && rising_edges[2] == 0U);
    send("wake\n"); expect("ok wake\r\n");
    send("state\n"); expect("state 100.000000 100.000000 0.000000\r\n");
    send("out 1 10\n"); expect("error not_set 3\r\n");
    send("set 1 12\nset 2 14\n");
    expect("ok set 1 12.000000\r\nok set 2 14.000000\r\n");
    send("wake\n"); expect("ok wake\r\n");
    assert(axes[0].limit == 19200U && axes[1].limit == 22400U);
    assert(axis_status(0).position == 9114 && axis_status(1).position == 9913);
    boot(); /* Reset restores measured defaults, not the runtime overrides. */
}

static void test_state_axis3_fallback_and_explicit_set(void)
{
    boot();
    send("stop 3\n"); expect("stopped 3 not_set\r\n");
    send("set 3 0\n"); expect("error range 3\r\n");
    send("measure 3 start\n"); expect("ok measure 3 start\r\n");
    advance(3000000U);
    send("state\n"); expect("state 0.000000 0.000000 25.000000\r\n");
    assert(!axes[2].configured && axes[2].limit == 0U && axis_status(2).running);
    send("measure 3 over\n"); expect("");
    advance(3750U);
    clear_output(); motion_poll(); expect("measure 3 0.500625\r\n");
    send("state\n"); expect("state 0.000000 0.000000 25.031250\r\n");
    send("out 50 10\n"); expect("error not_set 3\r\n");
    send("stop 3\n"); expect("stopped 3 not_set\r\n");
    assert(!axes[2].configured && axes[2].limit == 0U);
    send("set 3 4\nstate\n");
    expect("ok set 3 4.000000\r\nstate 0.000000 0.000000 12.515625\r\n");
    send("out 0 60\n"); expect("ok out 0.000000 60\r\n");
    advance(500625U);
    clear_output(); motion_poll(); expect("done 3 0.000000\r\n");
    send("measure 3 start\n"); expect("ok measure 3 start\r\n");
    advance(3000000U);
    send("state\n"); expect("state 0.000000 0.000000 25.000000\r\n");
    assert(!axes[2].configured && axes[2].limit == 6400U);
    send("stop 3\n"); expect("");
    advance(3750U);
    clear_output(); motion_poll(); expect("stopped 3 not_set\r\n");
}

static void test_state_still_requires_axes1_and2(void)
{
    boot();
    send("measure 2 start\n"); expect("ok measure 2 start\r\n");
    send("state\n"); expect("error not_set 2\r\n");
    send("go 0 0 10\n"); expect("error not_set 2\r\n");
    send("stop 2\n"); expect("");
    advance(3750U);
    clear_output(); motion_poll(); expect("stopped 2 not_set\r\n");
}

static void test_batch_go_and_out(void)
{
    boot();
    send("set 1 2\nset 2 2\nset 3 4\n");
    expect("ok set 1 2.000000\r\nok set 2 2.000000\r\nok set 3 4.000000\r\n");

    send("go 50 25 10\n");
    expect("ok go 50.000000 25.000000 10\r\n");
    assert(axis_status(0).running && axis_status(1).running);
    send("out 75 20\n");
    expect("ok out 75.000000 20\r\n");
    advance(9000000U);
    clear_output(); motion_poll();
    expect("done 1 50.000000\r\ndone 2 25.000000\r\ndone 3 75.000000\r\n");
    assert(rising_edges[1] == rising_edges[3]);
    assert(rising_edges[0] == 1600U && rising_edges[1] == 800U &&
           rising_edges[2] == 4800U && rising_edges[3] == 800U);

    send("go 50 25 10\n");
    expect("ok go 50.000000 25.000000 10\r\ndone 1 50.000000\r\ndone 2 25.000000\r\n");
    send("out 75 20\n");
    expect("ok out 75.000000 20\r\ndone 3 75.000000\r\n");
}

static void test_measure_set_state_and_return_to_zero(void)
{
    boot();
    send("state\r\n"); expect("state 0.000000 0.000000 0.000000\r\n");
    send("measure 1 start\r\n"); expect("ok measure 1 start\r\n");
    send("state\r\n"); expect("error not_set 1\r\n");
    send("go 0 0 10\n"); expect("error not_set 1\r\n");
    assert(GPIOA->BSRR == (GPIO_PIN_4 << 16U));
    advance(6002000U);
    send("measure 1 over\n"); expect("");
    advance(1750U);
    clear_output(); motion_poll(); expect("measure 1 1.000625\r\n");
    assert(axis_status(0).position == 1601 && !axis_status(0).running);

    send("set 1 1\n"); expect("error range 1\r\n");
    send("set 1 1.000625\nset 2 2\nset 3 3\nstate\n");
    expect("ok set 1 1.000625\r\nok set 2 2.000000\r\nok set 3 3.000000\r\n"
           "state 100.000000 0.000000 0.000000\r\n");
    send("set 1 2.00125\nstate\n");
    expect("ok set 1 2.001250\r\nstate 50.000000 0.000000 0.000000\r\n");
    assert(axis_status(0).position == 1601);

    send("go 0 0 10\n");
    expect("ok go 0.000000 0.000000 10\r\ndone 2 0.000000\r\n");
    assert(GPIOA->BSRR == GPIO_PIN_4);
    advance(6003750U);
    clear_output(); motion_poll(); expect("done 1 0.000000\r\n");
    send("go 0 0 10\n");
    expect("ok go 0.000000 0.000000 10\r\ndone 1 0.000000\r\ndone 2 0.000000\r\n");
}

static void test_validation_and_stop(void)
{
    boot();
    send("set 1 1\nset 2 1\nset 3 1\n");
    send("go 101 0 10\n"); expect("error range 1\r\n");
    send("go 0 101 10\n"); expect("error range 2\r\n");
    send("out 101 10\n"); expect("error range 3\r\n");
    send("go 0 1 0\n"); expect("error speed\r\n");
    send("go 0 1 10 extra\n"); expect("error syntax\r\n");
    send("go -1 1 10\n"); expect("error number\r\n");
    send("out 1 61\n"); expect("error speed\r\n");
    send("go 50 50 10\n"); expect("ok go 50.000000 50.000000 10\r\n");
    send("stop 2\n");
    advance(3750U);
    clear_output(); motion_poll();
    expect("stopped 2 0.062500\r\n");
    assert(!axis_status(1).running);
}

static void test_wake_stops_motion_and_discards_queued_command(void)
{
    boot();
    send("set 1 0.01\nset 2 0.02\nset 3 0.04\n");
    send("go 50 0 10\n");
    expect("ok go 50.000000 0.000000 10\r\ndone 2 0.000000\r\n");
    advance(30000U);
    clear_output(); motion_poll(); expect("done 1 50.000000\r\n");

    send("go 100 0 10\n"); expect("ok go 100.000000 0.000000 10\r\ndone 2 0.000000\r\n");
    send("wake\r\nstate\r\ngo 0 0 10\r\n"); expect("ok wake\r\n");
    advance(3750U);
    clear_output(); motion_poll(); expect("stopped 1 56.250000\r\n");
    send("state\n"); expect("state 56.250000 0.000000 0.000000\r\n");
}

static void test_coordinate_rounding_and_large_travel(void)
{
    boot();
    send("set 1 0.000625\nset 2 0.000625\n");
    send("go 100.000001 0 10\n"); expect("error range 1\r\n");
    send("go 49.999999 0 10\n");
    expect("ok go 0.000000 0.000000 10\r\ndone 1 0.000000\r\ndone 2 0.000000\r\n");
    send("go 50 0 10\n");
    expect("ok go 100.000000 0.000000 10\r\ndone 2 0.000000\r\n");
    advance(3750U);
    clear_output(); motion_poll(); expect("done 1 100.000000\r\n");

    boot();
    send("set 1 1000000\nset 2 1000000\n");
    send("go 100 0 10\n"); expect("ok go 100.000000 0.000000 10\r\ndone 2 0.000000\r\n");
    assert(axes[0].target == 1600000000 && axis_status(0).running);
}

int main(void)
{
    test_measured_startup_travel_and_wake();
    test_state_axis3_fallback_and_explicit_set();
    test_state_still_requires_axes1_and2();
    test_batch_go_and_out();
    test_measure_set_state_and_return_to_zero();
    test_validation_and_stop();
    test_wake_stops_motion_and_discards_queued_command();
    test_coordinate_rounding_and_large_travel();
    puts("PASS: measured startup travel, state-only fallback, go/out, gantry, measurement, wake and validation");
    return 0;
}
