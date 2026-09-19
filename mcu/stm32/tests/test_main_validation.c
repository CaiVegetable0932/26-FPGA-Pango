#include <setjmp.h>

/* Reuse the real-driver register/IRQ fixture and its PWM edge simulator. */
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
#include "../Core/Src/main.c"
#undef main

static char transmitted[8192];
static size_t transmitted_size;
static uint8_t *receive_target;
static uint32_t init_mask;
static uint8_t booting;
static uint8_t transmit_failure;
static uint32_t receive_failures;
static uint32_t error_rearms;
static USART_TypeDef mock_uart;
static jmp_buf boot_complete;

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
    if (receive_failures)
    {
        --receive_failures;
        return HAL_ERROR;
    }
    if (uart->RxState != HAL_UART_STATE_READY) return HAL_BUSY;
    if (uart->Instance->SR & (USART_SR_PE | USART_SR_FE | USART_SR_NE | USART_SR_ORE))
        ++error_rearms;
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
HAL_StatusTypeDef HAL_UART_Transmit(UART_HandleTypeDef *uart, uint8_t *data, uint16_t size, uint32_t timeout)
{
    assert(uart == &huart3 && timeout == 100U);
    if (transmit_failure)
    {
        if (booting) longjmp(boot_complete, 1);
        return HAL_ERROR;
    }
    assert(transmitted_size + size < sizeof(transmitted));
    memcpy(transmitted + transmitted_size, data, size);
    transmitted_size += size;
    transmitted[transmitted_size] = '\0';
    if (booting) longjmp(boot_complete, 1);
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
            if (mock_uart.SR & USART_SR_RXNE) mock_uart.SR |= USART_SR_ORE;
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
static void boot_uart(uint32_t flags, uint32_t failures, uint8_t failed_tx)
{
    reset_fixture();
    memset(axes, 0, sizeof(axes));
    rx_head = rx_tail = rx_fault = discard_line = 0U;
    command_length = 0U;
    init_mask = 0U;
    clear_output();
    booting = 1U;
    transmit_failure = failed_tx;
    receive_failures = failures;
    error_rearms = 0U;
    mock_uart = (USART_TypeDef){.SR = flags};
    receive_target = NULL;
    if (setjmp(boot_complete) == 0) firmware_main();
    booting = 0U;
    expect(failed_tx ? "" : "ready\r\n");
    assert(init_mask == 63U && gantry_enabled);
    for (uint32_t i = 0; i < 4U; ++i) assert(!(mock_timers[i].CR1 & TIM_CR1_CEN));
}
static void boot(void) { boot_uart(0U, 0U, 0U); }

static void test_wake_and_cold_start_recovery(void)
{
    boot_uart(USART_SR_FE | USART_SR_NE | USART_SR_ORE | USART_SR_RXNE, 0U, 0U);
    assert(mock_uart.SR == 0U && error_rearms == 0U);
    send("wake"); expect("");
    send("\r\n"); expect("ok wake\r\n");
    send("wake extra\n"); expect("error syntax\r\n");
    send("state\n"); expect("error not_set 1\r\n");
    send("set 1 0.01\nset 2 0.02\nset 3 0.04\n");
    send("go 50 1 10\n");
    advance(30000U);
    clear_output(); motion_poll(); expect("done 1 50.000000\r\n");
    send("\r\nwake\r\ngo 100 1 10\n"); expect("ok wake\r\n");
    /* Wake flushes queued commands and preserves the established coordinates. */
    assert(rising_edges[0] == 8U && !axis_status(0).running);
    send("wake\n"); expect("ok wake\r\n");
    send("state\n"); expect("state 50.000000 0.000000 0.000000\r\n");
    send("go 100 2 10\ngo 100 3 10\n");
    advance(2000U);
    send("wake\n"); expect("ok wake\r\n");
    advance(1750U);
    clear_output(); motion_poll();
    expect("stopped 2 3.125000\r\nstopped 3 1.562500\r\n");
    assert(!axis_status(1).running && !axis_status(2).running);
    assert(rising_edges[1] == rising_edges[3]);

    /* The ready message can be lost; a later peer still gets a wake reply. */
    boot_uart(0U, 0U, 1U);
    transmit_failure = 0U;
    send("\r\nwake\r\n"); expect("ok wake\r\n");

    /* A temporary receive-start failure must reach the loop instead of hanging. */
    boot_uart(USART_SR_ORE, 2U, 0U);
    assert(rx_fault && receive_failures == 1U);
    clear_output(); serial_poll(); expect("error serial_rx\r\n");
    assert(rx_fault && receive_failures == 0U);
    clear_output(); serial_poll(); expect("error serial_rx\r\n");
    assert(!rx_fault && error_rearms == 0U);
    send("\r\nwake\r\n"); expect("ok wake\r\n");

    /* Recover a silently stopped receiver, without requiring another RX IRQ. */
    mock_uart.CR1 &= ~UART_IT_RXNE;
    clear_output(); serial_poll(); expect("error serial_rx\r\n");
    send("\r\nwake\r\n"); expect("ok wake\r\n");
    huart3.RxState = HAL_UART_STATE_READY;
    clear_output(); serial_poll(); expect("error serial_rx\r\n");
    send("\r\nwake\r\n"); expect("ok wake\r\n");

    /* Match HAL's last-byte-before-error callback order; never execute that line. */
    send("set 1 2\n");
    receive("go 50 1 10");
    huart3.ErrorCode = HAL_UART_ERROR_ORE;
    mock_uart.SR |= USART_SR_ORE;
    receive("\n");
    assert(rx_fault && !(mock_uart.CR1 & UART_IT_RXNE));
    assert(huart3.ErrorCode == HAL_UART_ERROR_ORE);
    HAL_UART_ErrorCallback(&huart3);
    clear_output(); serial_poll(); expect("error serial_rx\r\n");
    assert(mock_uart.SR == 0U && error_rearms == 0U && !axis_status(0).running);
    send("\r\nwake\r\n"); expect("ok wake\r\n");

    receive_failures = 1U;
    send("s"); expect("error serial_rx\r\n");
    send("\r\nwake\r\n"); expect("ok wake\r\n");
    assert(error_rearms == 0U);
}

static void test_measure_and_coordinate(void)
{
    boot();
    send("state\r\n"); expect("error not_set 1\r\n");
    send("go 1 1 10\n"); expect("error not_set 1\r\n");
    send("measure 1 start\r\n"); expect("ok measure 1 start\r\n");
    assert(GPIOA->BSRR == (GPIO_PIN_4 << 16U));
    advance(6002000U);
    send("measure 1 over\n"); expect("");
    advance(1750U);
    motion_poll(); expect("measure 1 1.000625\r\n");
    assert(axis_status(0).position == 1601 && !axis_status(0).running);
    D36A_Status physical;
    assert(D36A_GetStatus(1U, &physical) == HAL_OK && physical.position == -1601);
    send("state\n"); expect("error not_set 1\r\n");
    send("set 1 1\n"); expect("error range 1\r\n");
    send("set 1 1.000625\n"); expect("ok set 1 1.000625\r\n");
    assert(axis_status(0).position == 1601);
    send("set 2 2\nset 3 3\nstate\n");
    expect("ok set 2 2.000000\r\nok set 3 3.000000\r\nstate 100.000000 0.000000 0.000000\r\n");
    send("set 1 2.00125\nstate\n");
    expect("ok set 1 2.001250\r\nstate 50.000000 0.000000 0.000000\r\n");
    assert(axis_status(0).position == 1601 && rising_edges[0] == 1601U);
    send("go 0 1 10\n"); expect("ok go 1 0.000000\r\n");
    assert(GPIOA->BSRR == GPIO_PIN_4);
    advance(6003750U);
    clear_output(); motion_poll(); expect("done 1 0.000000\r\n");
    send("go 0 1 10\n"); expect("ok go 1 0.000000\r\ndone 1 0.000000\r\n");
    send("go 101 1 10\n"); expect("error range 1\r\n");
    send("measure 1 start\n"); expect("ok measure 1 start\r\n");
    send("state\n"); expect("error not_set 1\r\n");
    send("measure 1 over\n");
    advance(3750U);
    motion_poll();
    assert(!axis_status(0).running);
}

static void test_gantry_and_concurrency(void)
{
    boot();
    send("set 1 2\nset 2 2\nset 3 2\n");
    send("go 50 2 10\n"); expect("ok go 2 50.000000\r\n");
    assert(GPIOA->BSRR == GPIO_PIN_2 && GPIOB->BSRR == (GPIO_PIN_5 << 16U));
    advance(3000000U);
    send("state\n"); expect("state 0.000000 25.000000 0.000000\r\n");
    send("go 0 2 10\n"); expect("error busy 2\r\n");
    send("set 2 1\n"); expect("error busy 2\r\n");
    send("go 25 3 20\n"); expect("ok go 3 25.000000\r\n");
    assert(GPIOB->BSRR == GPIO_PIN_11);
    advance(3000000U);
    clear_output(); motion_poll();
    expect("done 2 50.000000\r\ndone 3 25.000000\r\n");
    assert(rising_edges[1] == 1600U && rising_edges[3] == 1600U);
    send("measure 2 start\n"); expect("error not_zero 2\r\n");
    send("go 0 2 10\n");
    assert(GPIOA->BSRR == (GPIO_PIN_2 << 16U) && GPIOB->BSRR == GPIO_PIN_5);
    advance(6000000U);
    clear_output(); motion_poll(); expect("done 2 0.000000\r\n");
    send("measure 2 start\n"); expect("ok measure 2 start\r\n");
    advance(6000000U);
    send("measure 2 over\n");
    advance(3750U); motion_poll();
    expect("measure 2 1.000625\r\n");
    assert(rising_edges[1] == rising_edges[3]);
}

static void test_normalized_travel(void)
{
    boot();
    send("set 1 0.01\nset 2 0.02\nset 3 0.04\n");
    send("go 50 1 10\ngo 50 2 10\ngo 50 3 10\n");
    expect("ok go 1 50.000000\r\nok go 2 50.000000\r\nok go 3 50.000000\r\n");
    advance(120000U);
    clear_output(); motion_poll();
    expect("done 1 50.000000\r\ndone 2 50.000000\r\ndone 3 50.000000\r\n");
    assert(axis_status(0).position == 8 && axis_status(1).position == 16 &&
           axis_status(2).position == 32);
    send("state\n"); expect("state 50.000000 50.000000 50.000000\r\n");
    send("go 100 1 10\n");
    assert(GPIOA->BSRR == (GPIO_PIN_4 << 16U));
    send("go 100 2 10\ngo 100 3 10\n");
    advance(120000U);
    clear_output(); motion_poll();
    expect("done 1 100.000000\r\ndone 2 100.000000\r\ndone 3 100.000000\r\n");
    send("state\n"); expect("state 100.000000 100.000000 100.000000\r\n");
    send("go 0 1 10\n");
    assert(GPIOA->BSRR == GPIO_PIN_4);
    send("go 0 2 10\ngo 0 3 10\n");
    assert(GPIOB->BSRR == (GPIO_PIN_11 << 16U));
    advance(240000U);
    clear_output(); motion_poll();
    expect("done 1 0.000000\r\ndone 2 0.000000\r\ndone 3 0.000000\r\n");
    send("state\n"); expect("state 0.000000 0.000000 0.000000\r\n");
    assert(rising_edges[0] == 32U && rising_edges[1] == 64U &&
           rising_edges[2] == 128U && rising_edges[3] == 64U);

    /* One-microstep travel: rounding cannot send motion outside either endpoint. */
    boot();
    send("set 1 0.000625\n"); expect("ok set 1 0.000625\r\n");
    send("go 100.000001 1 10\n"); expect("error range 1\r\n");
    assert(!axis_status(0).running);
    send("go 49.999999 1 10\n"); expect("ok go 1 0.000000\r\ndone 1 0.000000\r\n");
    send("go 50 1 10\n"); expect("ok go 1 100.000000\r\n");
    advance(3750U);
    clear_output(); motion_poll(); expect("done 1 100.000000\r\n");
    send("go 100 1 10\n"); expect("ok go 1 100.000000\r\ndone 1 100.000000\r\n");
    assert(rising_edges[0] == 1U);

    /* Largest configured travel exercises 64-bit coordinate multiplication. */
    boot();
    send("set 1 1000000\n"); expect("ok set 1 1000000.000000\r\n");
    send("go 100 1 10\n"); expect("ok go 1 100.000000\r\n");
    assert(axes[0].target == 1600000000 && GPIOA->BSRR == (GPIO_PIN_4 << 16U));
    char coordinate[24];
    format_coordinate(0U, 1600000000, coordinate, sizeof(coordinate));
    assert(strcmp(coordinate, "100.000000") == 0);
    format_coordinate(0U, 800000000, coordinate, sizeof(coordinate));
    assert(strcmp(coordinate, "50.000000") == 0);

    boot();
    send("stop 1\n"); expect("stopped 1 not_set\r\n");
    send("measure 1 start\n");
    advance(2000U);
    send("stop 1\n");
    advance(1750U); motion_poll(); expect("stopped 1 not_set\r\n");
    assert(axis_status(0).position == 1 && !axis_status(0).running);
    send("set 1 0.000625\ngo 100 1 10\n");
    expect("ok set 1 0.000625\r\nok go 1 100.000000\r\ndone 1 100.000000\r\n");
}

static void test_parser_and_receive_faults(void)
{
    boot();
    send("set 1 2\nset 2 2\nset 3 2\n");
    const char *invalid[] = {"set 0 1\n", "set 4 1\n", "set 1 nan\n", "set 1 inf\n",
        "set 1 -1\n", "set 1 0\n", "set 1 1e3\n", "set 1 1000001\n", "go 1 1 0\n",
        "go 1 1 -5\n", "go 1 1 61\n", "go 1 1 1.5\n", "go 1 1 10 extra\n",
        "state extra\n", "measure 1 over\n", "measure 1 bogus\n", "set 1 1.0000001\n",
        "go -1 1 10\n", "go nan 1 10\n", "go 100.000001 1 10\n", "go 101 1 10\n"};
    for (uint32_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i)
    {
        send(invalid[i]);
        assert(strncmp(transmitted, "error ", 6U) == 0);
        assert(!axis_status(0).running);
    }
    send("go 0.03125 1 10\n");
    advance(3750U);
    clear_output(); motion_poll(); expect("done 1 0.031250\r\n");
    send("go 0.03 1 10\n"); expect("ok go 1 0.031250\r\ndone 1 0.031250\r\n");
    send("go 1 2 10\n");
    advance(2000U);
    send("stop 2\n");
    advance(1750U); motion_poll(); expect("stopped 2 0.031250\r\n");
    send("go 1 1 10\n");
    char overflow[RX_CAPACITY + 20U];
    memset(overflow, 'x', sizeof(overflow) - 1U); overflow[sizeof(overflow) - 1U] = '\0';
    send(overflow); expect("error serial_rx\r\n");
    advance(3750U); motion_poll();
    assert(!axis_status(0).running);
    send("\nstate\r\n"); assert(strncmp(transmitted, "state ", 6U) == 0);
    send("go 1 1 10\n");
    clear_output(); HAL_UART_ErrorCallback(&huart3); serial_poll();
    expect("error serial_rx\r\n");
    advance(3750U); motion_poll(); assert(!axis_status(0).running);
    send("\n");
    char long_line[120];
    memset(long_line, 'x', sizeof(long_line) - 2U);
    long_line[sizeof(long_line) - 2U] = '\n'; long_line[sizeof(long_line) - 1U] = '\0';
    send(long_line); expect("error line\r\n");
    send("sta"); expect("");
    send("te\r\n"); assert(strncmp(transmitted, "state ", 6U) == 0);
    send("go 1 2 10\n");
    transmit_failure = 1U;
    send("state\n");
    advance(3750U);
    transmit_failure = 0U;
    clear_output(); motion_poll();
    assert(!axis_status(1).running);
}

int main(void)
{
    test_wake_and_cold_start_recovery();
    test_measure_and_coordinate();
    test_gantry_and_concurrency();
    test_normalized_travel();
    test_parser_and_receive_faults();
    puts("PASS: actual main + driver: wake/cold-start recovery, direction, coordinates, gantry and UART faults");
    return 0;
}
