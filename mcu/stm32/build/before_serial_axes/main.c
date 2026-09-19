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
#include "gpio.h"

/* Private includes ----------------------------------------------------------*/
/* USER CODE BEGIN Includes */
#include "d36a_motor.h"
/* USER CODE END Includes */

/* Private typedef -----------------------------------------------------------*/
/* USER CODE BEGIN PTD */

/* USER CODE END PTD */

/* Private define ------------------------------------------------------------*/
/* USER CODE BEGIN PD */
#define MOTOR_TEST_RPM         5
/* Normal test: 1/8 microstepping, one forward revolution, then a pause. */
#define MOTOR_TEST_STARTUP_MS  10000U
#define MOTOR_TEST_PAUSE_MS    10000U
#define MOTOR_TEST_MOVE_MS     (60000U / MOTOR_TEST_RPM)
#define MOTOR_TEST_INTERVAL_MS (MOTOR_TEST_MOVE_MS + MOTOR_TEST_PAUSE_MS)

/* Saved short-burst settings; restore with the saved short-burst loop below.
#define MOTOR_TEST_STARTUP_MS  5000U
#define MOTOR_TEST_PAUSE_MS    10000U
#define MOTOR_TEST_INTERVAL_MS 200U
#define MOTOR_TEST_BURST_STEPS 20U
*/
/* USER CODE END PD */

/* Private macro -------------------------------------------------------------*/
/* USER CODE BEGIN PM */

/* USER CODE END PM */

/* Private variables ---------------------------------------------------------*/

/* USER CODE BEGIN PV */
/* Debugger observations of software execution, not measured driver signals. */
static volatile struct
{
  uint32_t firmware_tag;
  uint32_t reset_csr;
  uint32_t uptime_ms;
  /* 0=startup, 1=forward, 2=hold after forward, 3=reverse, 4=hold after reverse. */
  uint32_t phase;
  uint32_t phase_elapsed_ms;
  int32_t commanded_rpm;
  uint32_t pulse_commands_per_motor;
  uint32_t moves_started;
  uint32_t error_motor;
} d36a_diagnostic = { .firmware_tag = 0xD36A1001U };
/* USER CODE END PV */

/* Private function prototypes -----------------------------------------------*/
void SystemClock_Config(void);
/* USER CODE BEGIN PFP */

/* USER CODE END PFP */

/* Private user code ---------------------------------------------------------*/
/* USER CODE BEGIN 0 */

/* USER CODE END 0 */

/**
  * @brief  The application entry point.
  * @retval int
  */
int main(void)
{

  /* USER CODE BEGIN 1 */
  uint32_t last_motor_start;
  uint32_t motor_wait_ms = MOTOR_TEST_STARTUP_MS;
  /* Restore only for the saved alternating-direction test:
  int16_t next_motor_rpm = MOTOR_TEST_RPM;
  */
  /* Restore only for the saved short-burst test:
  uint32_t diagnostic_remaining = MOTOR_TEST_BURST_STEPS;
  */
  d36a_diagnostic.reset_csr = RCC->CSR;
  __HAL_RCC_CLEAR_RESET_FLAGS();
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
  /* USER CODE BEGIN 2 */
  /* CubeMX configured the peripherals; now wake the drivers with STEP low. */
  if (D36A_Control(1U, 0, 0U) != HAL_OK)
  {
    d36a_diagnostic.error_motor = 1U;
    Error_Handler();
  }
  last_motor_start = HAL_GetTick();
  /* USER CODE END 2 */

  /* Infinite loop */
  /* USER CODE BEGIN WHILE */
  while (1)
  {
    /* USER CODE END WHILE */

    /* USER CODE BEGIN 3 */
    uint32_t now = HAL_GetTick();
    d36a_diagnostic.uptime_ms = now;

    /* Active normal loop. Finite moves stop in the timer ISR. */
    if ((uint32_t)(now - last_motor_start) >= motor_wait_ms)
    {
      for (uint8_t motor = 1U; motor <= D36A_MOTOR_COUNT; ++motor)
      {
        if (D36A_Control(motor, MOTOR_TEST_RPM, D36A_PULSES_PER_REV) != HAL_OK)
        {
          d36a_diagnostic.error_motor = motor;
          Error_Handler();
        }
      }
      last_motor_start = HAL_GetTick();
      now = last_motor_start;
      motor_wait_ms = MOTOR_TEST_INTERVAL_MS;
      d36a_diagnostic.commanded_rpm = MOTOR_TEST_RPM;
      d36a_diagnostic.pulse_commands_per_motor += D36A_PULSES_PER_REV;
      ++d36a_diagnostic.moves_started;
    }

    /* Timing below describes commanded phases; it is not motion feedback. */
    uint32_t elapsed = (uint32_t)(now - last_motor_start);
    if (d36a_diagnostic.moves_started == 0U)
    {
      d36a_diagnostic.phase = 0U;
      d36a_diagnostic.phase_elapsed_ms = elapsed;
    }
    else
    {
      uint32_t phase = (d36a_diagnostic.commanded_rpm > 0) ? 1U : 3U;
      if (elapsed >= MOTOR_TEST_MOVE_MS)
      {
        ++phase;
        elapsed -= MOTOR_TEST_MOVE_MS;
      }
      d36a_diagnostic.phase = phase;
      d36a_diagnostic.phase_elapsed_ms = elapsed;
    }

    /* Saved short-burst loop. Use full-step DIP mode and the saved settings.
       Comment out the active normal loop and its phase reporting above first.
    if ((uint32_t)(now - last_motor_start) >= motor_wait_ms)
    {
      last_motor_start = now;
      motor_wait_ms = MOTOR_TEST_INTERVAL_MS;
      for (uint8_t motor = 1U; motor <= D36A_MOTOR_COUNT; ++motor)
      {
        if (D36A_Control(motor, MOTOR_TEST_RPM, 1U) != HAL_OK)
        {
          Error_Handler();
        }
      }
      if (--diagnostic_remaining == 0U)
      {
        diagnostic_remaining = MOTOR_TEST_BURST_STEPS;
        motor_wait_ms = MOTOR_TEST_PAUSE_MS;
      }
    }
    */

    /* Saved battery loop: alternate direction after each revolution and pause.
       Keep the active settings and restore next_motor_rpm above.
       Replace only the active normal loop; keep the shared phase reporting.
    if ((uint32_t)(now - last_motor_start) >= motor_wait_ms)
    {
      for (uint8_t motor = 1U; motor <= D36A_MOTOR_COUNT; ++motor)
      {
        if (D36A_Control(motor, next_motor_rpm, D36A_PULSES_PER_REV) != HAL_OK)
        {
          d36a_diagnostic.error_motor = motor;
          Error_Handler();
        }
      }
      last_motor_start = HAL_GetTick();
      now = last_motor_start;
      motor_wait_ms = MOTOR_TEST_INTERVAL_MS;
      d36a_diagnostic.commanded_rpm = next_motor_rpm;
      d36a_diagnostic.pulse_commands_per_motor += D36A_PULSES_PER_REV;
      ++d36a_diagnostic.moves_started;
      next_motor_rpm = -next_motor_rpm;
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
