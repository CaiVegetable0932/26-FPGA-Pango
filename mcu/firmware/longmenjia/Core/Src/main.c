/* USER CODE BEGIN Header */
/**
  ******************************************************************************
  * @file           : main.c
  * @brief          : Main program body
  ******************************************************************************
  * @attention
  *
  * Copyright (c) 2026 STMicroelectronics.
  * All rights reserved.
  *
  * This software is licensed under terms that can be found in the LICENSE file
  * in the root directory of this software component.
  * If no LICENSE file comes with this software, it is provided AS-IS.
  *
  ******************************************************************************
  */
/* USER CODE END Header */
/* Includes ------------------------------------------------------------------*/
#include "main.h"
#include "tim.h"
#include "usart.h"
#include "gpio.h"

/* Private includes ----------------------------------------------------------*/
/* USER CODE BEGIN Includes */
#include "d36a_motor.h"
#ifdef MCU_POSE_V2
#include "f4_link.h"
#endif
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
/* USER CODE END Includes */

/* Private typedef -----------------------------------------------------------*/
/* USER CODE BEGIN PTD */

/* USER CODE END PTD */

/* Private define ------------------------------------------------------------*/
/* USER CODE BEGIN PD */
#define AXIS_COUNT 3U
#define MEASURE_RPM 10
#define MAX_TRAVEL_PULSES (1000000U * D36A_PULSES_PER_REV)
#define DECIMAL_SCALE 1000000U
#define COORDINATE_SCALE (100U * DECIMAL_SCALE)
#define RX_CAPACITY 512U
#define LINE_CAPACITY 96U
/* Logical-axis travel measured on the mechanism, reported 2026-09-25. */
#define AXIS1_STARTUP_TRAVEL "5.696250"
#define AXIS2_STARTUP_TRAVEL "6.195625"
/* Temporary display scale only: axis 3 has not been measured or configured. */
#define AXIS3_STATE_FALLBACK_PULSES (2U * D36A_PULSES_PER_REV)
/* USER CODE END PD */

/* Private macro -------------------------------------------------------------*/
/* USER CODE BEGIN PM */

/* USER CODE END PM */

/* Private variables ---------------------------------------------------------*/

/* USER CODE BEGIN PV */
typedef enum { AXIS_IDLE, AXIS_MEASURE, AXIS_MEASURE_STOP, AXIS_GO, AXIS_STOP } AxisMode;
static struct
{
  uint32_t limit;
  int32_t target;
  uint8_t configured;
#ifdef MCU_POSE_V2
  uint8_t failed;
#endif
  AxisMode mode;
} axes[AXIS_COUNT];
static const uint8_t axis_motor[AXIS_COUNT] = {1U, D36A_GANTRY, 4U};
/* Logical positive travel: axis 1 DIR low; axes 2 and 3 keep their polarity. */
static const int16_t axis_direction[AXIS_COUNT] = {-1, 1, 1};
#ifndef MCU_POSE_V2
static uint8_t rx_byte;
static volatile uint8_t rx_ring[RX_CAPACITY];
static volatile uint16_t rx_head, rx_tail;
static volatile uint8_t rx_fault;
static char command_line[LINE_CAPACITY];
static uint32_t command_length;
static uint8_t discard_line;
#endif
#ifdef MCU_POSE_V2
static uint8_t manual_zero;
static char *legacy_output;
static unsigned legacy_capacity;
#endif
/* USER CODE END PV */

/* Private function prototypes -----------------------------------------------*/
void SystemClock_Config(void);
/* USER CODE BEGIN PFP */

/* USER CODE END PFP */

/* Private user code ---------------------------------------------------------*/
/* USER CODE BEGIN 0 */
static HAL_StatusTypeDef axis_control(uint32_t i, int16_t rpm, uint32_t pulses)
{
  return D36A_Control(axis_motor[i], (int16_t)(rpm * axis_direction[i]), pulses);
}

static void stop_all(void)
{
  for (uint32_t i = 0; i < AXIS_COUNT; ++i)
  {
    if (axis_control(i, 0, 0U) != HAL_OK) Error_Handler();
    if (axes[i].mode != AXIS_IDLE) axes[i].mode = AXIS_STOP;
  }
}

static void reply(const char *format, ...)
{
  char output[128];
  va_list args;
  va_start(args, format);
  int length = vsnprintf(output, sizeof(output), format, args);
  va_end(args);
#ifdef MCU_POSE_V2
  if (legacy_output && length>0 && length<(int)sizeof(output)) {
    size_t used=strlen(legacy_output);
    if (used+(size_t)length<legacy_capacity) memcpy(legacy_output+used,output,(size_t)length+1);
  }
  else if (length>0 && length<(int)sizeof(output)) F4_LegacyNotice(output);
  return;
#endif
  if (length <= 0 || length >= (int)sizeof(output) ||
      HAL_UART_Transmit(&huart3, (uint8_t *)output, (uint16_t)length, 100U) != HAL_OK)
  {
    stop_all();
  }
}

#ifndef MCU_POSE_V2
static void serial_fault(void)
{
  /* Stop a persistent error IRQ from starving the main-loop recovery. */
  __HAL_UART_DISABLE_IT(&huart3, UART_IT_RXNE);
  __HAL_UART_DISABLE_IT(&huart3, UART_IT_PE);
  __HAL_UART_DISABLE_IT(&huart3, UART_IT_ERR);
  rx_fault = 1U;
}

static HAL_StatusTypeDef serial_restart(uint8_t discard)
{
  uint32_t mask = __get_PRIMASK();
  __disable_irq();
  /* No UART DMA is used: abort does not wait here. Clear SR then DR before
     rearming; HAL_UART_Abort alone leaves the hardware error flags set. */
  HAL_StatusTypeDef result = HAL_UART_Abort(&huart3);
  __HAL_UART_CLEAR_OREFLAG(&huart3);
  HAL_NVIC_ClearPendingIRQ(USART3_IRQn);
  rx_head = rx_tail = 0U;
  command_length = 0U;
  discard_line = discard;
  rx_fault = 0U;
  if (result == HAL_OK) result = HAL_UART_Receive_IT(&huart3, &rx_byte, 1U);
  if (result != HAL_OK) serial_fault();
  HAL_NVIC_EnableIRQ(USART3_IRQn);
  __set_PRIMASK(mask);
  return result;
}
#endif

static D36A_Status axis_status(uint32_t i)
{
  D36A_Status status = {0};
  if (D36A_GetStatus(axis_motor[i], &status) != HAL_OK) Error_Handler();
  status.position *= axis_direction[i];
  return status;
}

static void format_revolutions(int32_t pulses, char *output, size_t size)
{
  uint32_t magnitude = (pulses < 0) ? (uint32_t)(-(int64_t)pulses) : (uint32_t)pulses;
  snprintf(output, size, "%s%lu.%06lu", pulses < 0 ? "-" : "",
           (unsigned long)(magnitude / D36A_PULSES_PER_REV),
           (unsigned long)(((uint64_t)(magnitude % D36A_PULSES_PER_REV) * 1000000U) /
                           D36A_PULSES_PER_REV));
}

/* limit must be nonzero; positions are logical microsteps. */
static void format_coordinate(uint32_t limit, int32_t pulses, char *output, size_t size)
{
  uint32_t magnitude = (pulses < 0) ? (uint32_t)(-(int64_t)pulses) : (uint32_t)pulses;
  uint64_t value = ((uint64_t)magnitude * COORDINATE_SCALE + limit / 2U) / limit;
  snprintf(output, size, "%s%lu.%06lu", pulses < 0 ? "-" : "",
           (unsigned long)(value / DECIMAL_SCALE),
           (unsigned long)(value % DECIMAL_SCALE));
}

/* Parse exact millionths before range checks and microstep rounding. */
static uint8_t parse_decimal(const char *text, uint64_t *value)
{
  uint64_t whole = 0U, fraction = 0U, scale = 1U;
  const char *p = text;
  if (*p < '0' || *p > '9') return 0U;
  while (*p >= '0' && *p <= '9')
  {
    whole = whole * 10U + (uint32_t)(*p++ - '0');
    if (whole > 1000000U) return 0U;
  }
  if (*p == '.')
  {
    ++p;
    if (*p < '0' || *p > '9') return 0U;
    while (*p >= '0' && *p <= '9')
    {
      if (scale == DECIMAL_SCALE) return 0U;
      fraction = fraction * 10U + (uint32_t)(*p++ - '0');
      scale *= 10U;
    }
  }
  if (*p != '\0' || (whole == 1000000U && fraction != 0U)) return 0U;
  *value = whole * DECIMAL_SCALE + fraction * (DECIMAL_SCALE / scale);
  return 1U;
}

static uint8_t parse_axis(const char *text, uint32_t *index)
{
  if (text[0] < '1' || text[0] > '3' || text[1] != '\0') return 0U;
  *index = (uint32_t)(text[0] - '1');
  return 1U;
}

static uint8_t parse_speed(const char *text, int16_t *speed)
{
  uint32_t value = 0U;
  if (*text == '\0') return 0U;
  while (*text >= '0' && *text <= '9')
  {
    value = value * 10U + (uint32_t)(*text++ - '0');
    if (value > D36A_MAX_RPM) return 0U;
  }
  if (*text != '\0' || value == 0U) return 0U;
  *speed = (int16_t)value;
  return 1U;
}

static void motion_poll(void)
{
  for (uint32_t i = 0U; i < AXIS_COUNT; ++i)
  {
    if (axes[i].mode == AXIS_IDLE) continue;
    D36A_Status status = axis_status(i);
    if (status.running) continue;
    AxisMode finished = axes[i].mode;
    axes[i].mode = AXIS_IDLE;
    char position[24];
    if (finished == AXIS_MEASURE_STOP)
    {
      format_revolutions(status.position, position, sizeof(position));
      reply("measure %lu %s\r\n", (unsigned long)i + 1U, position);
    }
    else if (finished == AXIS_GO && status.position == axes[i].target)
    {
      format_coordinate(axes[i].limit, status.position, position, sizeof(position));
      reply("done %lu %s\r\n", (unsigned long)i + 1U, position);
    }
    else if (finished == AXIS_STOP)
    {
      if (axes[i].configured)
      {
        format_coordinate(axes[i].limit, status.position, position, sizeof(position));
        reply("stopped %lu %s\r\n", (unsigned long)i + 1U, position);
      }
      else reply("stopped %lu not_set\r\n", (unsigned long)i + 1U);
    }
    else
    {
#ifdef MCU_POSE_V2
      axes[i].failed=1;
#endif
      reply("error travel_limit %lu\r\n", (unsigned long)i + 1U);
    }
  }
}

static void execute_command(char *line)
{
  char *tokens[5];
  uint32_t count = 0U, i;
  char *token = strtok(line, " \t");
  while (token != NULL && count < 5U)
  {
    tokens[count++] = token;
    token = strtok(NULL, " \t");
  }
  if (count == 0U) return;
  if (strcmp(tokens[0], "wake") == 0 && count == 1U)
  {
    /* A reconnect cancels motion but must never invent a new physical zero. */
    stop_all();
#ifndef MCU_POSE_V2
    if (serial_restart(0U) != HAL_OK) { reply("error serial_rx\r\n"); return; }
#endif
    reply("ok wake\r\n");
    return;
  }
  if (strcmp(tokens[0], "state") == 0 && count == 1U)
  {
    char position[AXIS_COUNT][24];
    for (i = 0U; i < AXIS_COUNT; ++i)
    {
      uint32_t limit = axes[i].limit;
      if (!axes[i].configured)
      {
        if (i != 2U)
        {
          reply("error not_set %lu\r\n", (unsigned long)i + 1U);
          return;
        }
        /* Never mark axis 3 configured or change its movement limits here. */
        limit = AXIS3_STATE_FALLBACK_PULSES;
      }
      format_coordinate(limit, axis_status(i).position, position[i], sizeof(position[i]));
    }
    reply("state %s %s %s\r\n", position[0], position[1], position[2]);
    return;
  }
  uint8_t measure = strcmp(tokens[0], "measure") == 0 && count == 3U;
  uint8_t set = strcmp(tokens[0], "set") == 0 && count == 3U;
  uint8_t go = strcmp(tokens[0], "go") == 0 && count == 4U;
  uint8_t out = strcmp(tokens[0], "out") == 0 && count == 3U;
  uint8_t stop = strcmp(tokens[0], "stop") == 0 && count == 2U;

  if (go)
  {
    uint64_t x_number, y_number;
    uint32_t target[2], distance[2];
    int16_t rpm;
    D36A_Status status[2];
    char coordinate[2][24];

    if (!parse_decimal(tokens[1], &x_number) || !parse_decimal(tokens[2], &y_number))
    {
      reply("error number\r\n");
      return;
    }
    if (!parse_speed(tokens[3], &rpm))
    {
      reply("error speed\r\n");
      return;
    }
    for (i = 0U; i < 2U; ++i)
    {
      status[i] = axis_status(i);
      if (!axes[i].configured)
      {
        reply("error not_set %lu\r\n", (unsigned long)i + 1U);
        return;
      }
      if (axes[i].mode != AXIS_IDLE || status[i].running)
      {
        reply("error busy %lu\r\n", (unsigned long)i + 1U);
        return;
      }
    }
    if (x_number > COORDINATE_SCALE)
    {
      reply("error range 1\r\n");
      return;
    }
    if (y_number > COORDINATE_SCALE)
    {
      reply("error range 2\r\n");
      return;
    }
    target[0] = (uint32_t)((x_number * axes[0].limit + COORDINATE_SCALE / 2U) /
                           COORDINATE_SCALE);
    target[1] = (uint32_t)((y_number * axes[1].limit + COORDINATE_SCALE / 2U) /
                           COORDINATE_SCALE);
    for (i = 0U; i < 2U; ++i)
    {
      format_coordinate(axes[i].limit, (int32_t)target[i], coordinate[i], sizeof(coordinate[i]));
      distance[i] = (uint32_t)((target[i] >= (uint32_t)status[i].position) ?
                               (target[i] - (uint32_t)status[i].position) :
                               ((uint32_t)status[i].position - target[i]));
    }

    /* Arm the gantry first so both axes are accepted before the response. */
    if (distance[1] != 0U &&
        axis_control(1U, target[1] > (uint32_t)status[1].position ? rpm : -rpm,
                     distance[1]) != HAL_OK)
    {
      reply("error driver\r\n");
      return;
    }
    if (distance[0] != 0U &&
        axis_control(0U, target[0] > (uint32_t)status[0].position ? rpm : -rpm,
                     distance[0]) != HAL_OK)
    {
      if (distance[1] != 0U) (void)axis_control(1U, 0, 0U);
      reply("error driver\r\n");
      return;
    }
    for (i = 0U; i < 2U; ++i)
    {
      if (distance[i] != 0U)
      {
        axes[i].target = (int32_t)target[i];
        axes[i].mode = AXIS_GO;
      }
    }
    reply("ok go %s %s %d\r\n", coordinate[0], coordinate[1], (int)rpm);
    for (i = 0U; i < 2U; ++i)
    {
      if (distance[i] == 0U) reply("done %lu %s\r\n", (unsigned long)i + 1U, coordinate[i]);
    }
    return;
  }

  if (out)
  {
    uint64_t number;
    uint32_t target, distance;
    int16_t rpm;
    D36A_Status status;
    char coordinate[24];

    if (!parse_decimal(tokens[1], &number)) { reply("error number\r\n"); return; }
    if (!parse_speed(tokens[2], &rpm)) { reply("error speed\r\n"); return; }
    i = 2U;
    status = axis_status(i);
    if (!axes[i].configured) { reply("error not_set 3\r\n"); return; }
    if (axes[i].mode != AXIS_IDLE || status.running) { reply("error busy 3\r\n"); return; }
    if (number > COORDINATE_SCALE) { reply("error range 3\r\n"); return; }
    target = (uint32_t)((number * axes[i].limit + COORDINATE_SCALE / 2U) /
                        COORDINATE_SCALE);
    format_coordinate(axes[i].limit, (int32_t)target, coordinate, sizeof(coordinate));
    distance = (uint32_t)((target >= (uint32_t)status.position) ?
                          (target - (uint32_t)status.position) :
                          ((uint32_t)status.position - target));
    if (distance == 0U)
    {
      reply("ok out %s %d\r\n", coordinate, (int)rpm);
      reply("done 3 %s\r\n", coordinate);
      return;
    }
    if (axis_control(i, target > (uint32_t)status.position ? rpm : -rpm, distance) != HAL_OK)
    {
      reply("error driver\r\n");
      return;
    }
    axes[i].target = (int32_t)target;
    axes[i].mode = AXIS_GO;
    reply("ok out %s %d\r\n", coordinate, (int)rpm);
    return;
  }

  if (!(measure || set || stop)) { reply("error syntax\r\n"); return; }
  if (!parse_axis(tokens[1], &i)) { reply("error axis\r\n"); return; }
  D36A_Status status = axis_status(i);
  unsigned long n = (unsigned long)i + 1U;
  if (measure && strcmp(tokens[2], "over") == 0)
  {
    if (axes[i].mode != AXIS_MEASURE) { reply("error not_measuring %lu\r\n", n); return; }
    if (axis_control(i, 0, 0U) != HAL_OK) { reply("error driver\r\n"); return; }
    axes[i].mode = AXIS_MEASURE_STOP;
    return;
  }
  if (stop)
  {
    if (axis_control(i, 0, 0U) != HAL_OK) { reply("error driver\r\n"); return; }
    axes[i].mode = AXIS_STOP;
    return;
  }
  if (axes[i].mode != AXIS_IDLE || status.running) { reply("error busy %lu\r\n", n); return; }
  if (measure)
  {
    if (strcmp(tokens[2], "start") != 0) { reply("error syntax\r\n"); return; }
    if (status.position != 0) { reply("error not_zero %lu\r\n", n); return; }
    if (axis_control(i, MEASURE_RPM, MAX_TRAVEL_PULSES) != HAL_OK)
      { reply("error driver\r\n"); return; }
    axes[i].configured = 0U;
#ifdef MCU_POSE_V2
    axes[i].failed=0;
    F4_ConfigChanged();
#endif
    axes[i].mode = AXIS_MEASURE;
    reply("ok measure %lu start\r\n", n);
    return;
  }
  uint64_t number;
  if (!parse_decimal(tokens[2], &number)) { reply("error number\r\n"); return; }
  char coordinate[24];
  if (set)
  {
    uint32_t value = (uint32_t)((number * D36A_PULSES_PER_REV + DECIMAL_SCALE / 2U) /
                                DECIMAL_SCALE);
    if (value == 0U || status.position < 0 || value < (uint32_t)status.position)
      { reply("error range %lu\r\n", n); return; }
    axes[i].limit = value;
    axes[i].configured = 1U;
#ifdef MCU_POSE_V2
    F4_ConfigChanged();
#endif
    format_revolutions((int32_t)value, coordinate, sizeof(coordinate));
    reply("ok set %lu %s\r\n", n, coordinate);
    return;
  }
  reply("error syntax\r\n");
}

#ifndef MCU_POSE_V2
void HAL_UART_RxCpltCallback(UART_HandleTypeDef *uart)
{
  if (uart != &huart3) return;
  /* HAL can deliver the final byte before its error callback. Rearming here
     would erase ErrorCode and could accept a corrupted command. */
  if (rx_fault || uart->ErrorCode != HAL_UART_ERROR_NONE)
  {
    serial_fault();
    return;
  }
  uint16_t next = (uint16_t)((rx_head + 1U) % RX_CAPACITY);
  if (next == rx_tail)
  {
    serial_fault();
    return;
  }
  rx_ring[rx_head] = rx_byte;
  rx_head = next;
  if (HAL_UART_Receive_IT(&huart3, &rx_byte, 1U) != HAL_OK) serial_fault();
}

void HAL_UART_ErrorCallback(UART_HandleTypeDef *uart)
{
  if (uart == &huart3) serial_fault();
}

static void serial_poll(void)
{
  /* Recover even if an aborted transfer never delivered an error callback. */
  if (!rx_fault && (huart3.RxState != HAL_UART_STATE_BUSY_RX ||
                    __HAL_UART_GET_IT_SOURCE(&huart3, UART_IT_RXNE) == RESET))
    serial_fault();
  if (rx_fault)
  {
    stop_all();
    serial_restart(1U);
    reply("error serial_rx\r\n");
    return;
  }
  /* Bound work per pass so completion reports and receive faults stay responsive. */
  for (uint32_t budget = 0U; budget < RX_CAPACITY && rx_tail != rx_head && !rx_fault; ++budget)
  {
    char ch = (char)rx_ring[rx_tail];
    rx_tail = (uint16_t)((rx_tail + 1U) % RX_CAPACITY);
    if (ch == '\r' || ch == '\n')
    {
      if (!discard_line)
      {
        command_line[command_length] = '\0';
        motion_poll();
        execute_command(command_line);
      }
      discard_line = 0U;
      command_length = 0U;
    }
    else if (!discard_line)
    {
      if ((ch != '\t' && (ch < 32 || ch > 126)) || command_length >= LINE_CAPACITY - 1U)
      {
        discard_line = 1U;
        stop_all();
        reply("error line\r\n");
      }
      else command_line[command_length++] = ch;
    }
  }
}
#endif

#ifdef MCU_POSE_V2
void F4_AxesSnapshot(int32_t position[3], uint32_t limit[3], uint8_t *busy, uint8_t *valid)
{
  *busy=0; *valid=0;
  uint32_t irq=__get_PRIMASK(); __disable_irq();
  for (unsigned i=0;i<3;i++) {
    D36A_Status s=axis_status(i); limit[i]=axes[i].configured ? axes[i].limit : 0;
    position[i]=limit[i] ? (int32_t)(((int64_t)s.position*COORDINATE_SCALE)/limit[i]) : 0;
    if (s.running || axes[i].mode!=AXIS_IDLE) *busy|=(uint8_t)(1U<<i);
    if (limit[i] && (manual_zero&(1U<<i)) && s.position>=0 && (uint32_t)s.position<=limit[i])
      *valid|=(uint8_t)(1U<<i);
  }
  __set_PRIMASK(irq);
}
uint8_t F4_AxesMove(uint8_t mask, const int32_t target[3], const uint16_t rpm[3])
{
  D36A_Status s[3]; uint32_t pulses[3], distances[3];
  for (unsigned i=0;i<3;i++) if (mask&(1U<<i)) {
    s[i]=axis_status(i);
    if (!axes[i].configured || !(manual_zero&(1U<<i))) return 7;
    if (axes[i].mode!=AXIS_IDLE || s[i].running) return 2;
    if (target[i]<0 || target[i]>(int32_t)COORDINATE_SCALE || !rpm[i] || rpm[i]>60) return 4;
    pulses[i]=(uint32_t)(((uint64_t)target[i]*axes[i].limit+COORDINATE_SCALE/2)/COORDINATE_SCALE);
    distances[i]=(uint32_t)(pulses[i]>(uint32_t)s[i].position ? pulses[i]-(uint32_t)s[i].position : (uint32_t)s[i].position-pulses[i]);
  }
  for (unsigned i=0;i<3;i++) if ((mask&(1U<<i)) && distances[i]) {
    int16_t speed=(int16_t)rpm[i];
    if (pulses[i]<(uint32_t)s[i].position) speed=-speed;
    if (axis_control(i,speed,distances[i])!=HAL_OK) { stop_all(); return 9; }
    axes[i].target=(int32_t)pulses[i]; axes[i].mode=AXIS_GO;
    axes[i].failed=0;
  }
  return 1;
}
void F4_AxesStop(void) { stop_all(); }
uint8_t F4_AxesResult(uint8_t mask)
{
  for (unsigned i=0;i<3;i++) if (mask&(1U<<i)) {
    if (axes[i].failed) return 9;
    if (axes[i].mode!=AXIS_IDLE || axis_status(i).running) return 1;
  }
  return 0;
}
uint8_t F4_ManualZero(uint8_t mask)
{
  if (!mask || (mask&~7U)) return 4;
  for (unsigned i=0;i<3;i++) if (mask&(1U<<i)) {
    D36A_Status s=axis_status(i);
    if (s.running || axes[i].mode!=AXIS_IDLE || s.position!=0) return 7;
  }
  manual_zero|=mask; return 0;
}
void F4_Legacy(char *line, char *output, unsigned capacity)
{
  for (unsigned i=0;i<3;i++) if (axes[i].mode==AXIS_IDLE) axes[i].failed=0;
  legacy_output=output; legacy_capacity=capacity; output[0]=0;
  execute_command(line); legacy_output=0;
}
void HAL_UART_RxCpltCallback(UART_HandleTypeDef *uart) { F4_Link_Rx(uart); }
void HAL_UART_ErrorCallback(UART_HandleTypeDef *uart) { F4_Link_Error(uart); }
void HAL_UART_TxCpltCallback(UART_HandleTypeDef *uart) { F4_Link_TxDone(uart); }
#endif

/* USER CODE END 0 */

/**
  * @brief  The application entry point.
  * @retval int
  */
int main(void)
{

  /* USER CODE BEGIN 1 */
  /* Saved automatic validation local (restore only with its loop below):
  uint32_t last_motor_start = 0U, motor_wait_ms = 10000U;
  */
  /* USER CODE END 1 */

  /* MCU Configuration--------------------------------------------------------*/

  /* Reset of all peripherals, Initializes the Flash interface and the Systick. */
  HAL_Init();

  /* USER CODE BEGIN Init */

  /* USER CODE END Init */

  /* Configure the system clock */
  SystemClock_Config();

  /* USER CODE BEGIN SysInit */

  /* USER CODE END SysInit */

  /* Initialize all configured peripherals */
  MX_GPIO_Init();
  MX_TIM2_Init();
  MX_TIM3_Init();
  MX_TIM4_Init();
  MX_TIM5_Init();
  MX_USART3_UART_Init();
  /* USER CODE BEGIN 2 */
  /* CubeMX configured the peripherals; now wake the drivers with STEP low. */
  if (D36A_Control(D36A_GANTRY, 0, 0U) != HAL_OK)
  {
    Error_Handler();
  }
  /* A transient receive failure is retried by serial_poll, not a fatal boot error. */
#ifndef MCU_POSE_V2
  serial_restart(0U);
#endif
  reply("ready\r\n");
  /* Reuse set validation/replies after ready, before consuming host commands. */
  char startup_axis1[] = "set 1 " AXIS1_STARTUP_TRAVEL;
  char startup_axis2[] = "set 2 " AXIS2_STARTUP_TRAVEL;
  execute_command(startup_axis1);
  execute_command(startup_axis2);
#ifdef MCU_POSE_V2
  F4_Link_Init();
#endif
  /* USER CODE END 2 */

  /* Infinite loop */
  /* USER CODE BEGIN WHILE */
  while (1)
  {
    /* USER CODE END WHILE */

    /* USER CODE BEGIN 3 */
#ifdef MCU_POSE_V2
    F4_Link_Poll();
#else
    serial_poll();
#endif
    motion_poll();
    /* Previous automatic validation is archived in build/before_serial_axes/main.c.
       Do not restore independent motor 2/3 motion on an assembled gantry.
       For a detached motor bench only: replace the gantry initialization with
       D36A_Control(1U, 0, 0U), disable serial_poll/motion_poll, restore the local.
    uint32_t now = HAL_GetTick();
    if ((uint32_t)(now - last_motor_start) >= motor_wait_ms)
    {
      last_motor_start = now;
      motor_wait_ms = 22000U;
      for (uint8_t motor = 1U; motor <= D36A_MOTOR_COUNT; ++motor)
      {
        if (D36A_Control(motor, 5, D36A_PULSES_PER_REV) != HAL_OK) Error_Handler();
      }
    }
    */
  }
  /* USER CODE END 3 */
}

/**
  * @brief System Clock Configuration
  * @retval None
  */
void SystemClock_Config(void)
{
  RCC_OscInitTypeDef RCC_OscInitStruct = {0};
  RCC_ClkInitTypeDef RCC_ClkInitStruct = {0};

  /** Configure the main internal regulator output voltage
  */
  __HAL_RCC_PWR_CLK_ENABLE();
  __HAL_PWR_VOLTAGESCALING_CONFIG(PWR_REGULATOR_VOLTAGE_SCALE1);

  /** Initializes the RCC Oscillators according to the specified parameters
  * in the RCC_OscInitTypeDef structure.
  */
  RCC_OscInitStruct.OscillatorType = RCC_OSCILLATORTYPE_HSI;
  RCC_OscInitStruct.HSIState = RCC_HSI_ON;
  RCC_OscInitStruct.HSICalibrationValue = RCC_HSICALIBRATION_DEFAULT;
  RCC_OscInitStruct.PLL.PLLState = RCC_PLL_NONE;
#ifdef MCU_POSE_V2
  RCC_OscInitStruct.PLL.PLLState=RCC_PLL_ON;
  RCC_OscInitStruct.PLL.PLLSource=RCC_PLLSOURCE_HSI;
  RCC_OscInitStruct.PLL.PLLM=8;
  RCC_OscInitStruct.PLL.PLLN=192;
  RCC_OscInitStruct.PLL.PLLP=RCC_PLLP_DIV4;
  RCC_OscInitStruct.PLL.PLLQ=8;
#endif
  if (HAL_RCC_OscConfig(&RCC_OscInitStruct) != HAL_OK)
  {
    Error_Handler();
  }

  /** Initializes the CPU, AHB and APB buses clocks
  */
  RCC_ClkInitStruct.ClockType = RCC_CLOCKTYPE_HCLK|RCC_CLOCKTYPE_SYSCLK
                              |RCC_CLOCKTYPE_PCLK1|RCC_CLOCKTYPE_PCLK2;
  RCC_ClkInitStruct.SYSCLKSource = RCC_SYSCLKSOURCE_HSI;
  RCC_ClkInitStruct.AHBCLKDivider = RCC_SYSCLK_DIV1;
  RCC_ClkInitStruct.APB1CLKDivider = RCC_HCLK_DIV1;
  RCC_ClkInitStruct.APB2CLKDivider = RCC_HCLK_DIV1;
#ifdef MCU_POSE_V2
  RCC_ClkInitStruct.SYSCLKSource=RCC_SYSCLKSOURCE_PLLCLK;
  RCC_ClkInitStruct.APB1CLKDivider=RCC_HCLK_DIV4;
  RCC_ClkInitStruct.APB2CLKDivider=RCC_HCLK_DIV2;
  if (HAL_RCC_ClockConfig(&RCC_ClkInitStruct,FLASH_LATENCY_3)!=HAL_OK) Error_Handler();
  return;
#endif

  if (HAL_RCC_ClockConfig(&RCC_ClkInitStruct, FLASH_LATENCY_0) != HAL_OK)
  {
    Error_Handler();
  }
}

/* USER CODE BEGIN 4 */

/* USER CODE END 4 */

/**
  * @brief  This function is executed in case of error occurrence.
  * @retval None
  */
void Error_Handler(void)
{
  /* USER CODE BEGIN Error_Handler_Debug */
  /* User can add his own implementation to report the HAL error return state */
  __disable_irq();
  while (1)
  {
  }
  /* USER CODE END Error_Handler_Debug */
}
#ifdef USE_FULL_ASSERT
/**
  * @brief  Reports the name of the source file and the source line number
  *         where the assert_param error has occurred.
  * @param  file: pointer to the source file name
  * @param  line: assert_param error line source number
  * @retval None
  */
void assert_failed(uint8_t *file, uint32_t line)
{
  /* USER CODE BEGIN 6 */
  /* User can add his own implementation to report the file name and line number,
     ex: printf("Wrong parameters value: file %s on line %d\r\n", file, line) */
  /* USER CODE END 6 */
}
#endif /* USE_FULL_ASSERT */
