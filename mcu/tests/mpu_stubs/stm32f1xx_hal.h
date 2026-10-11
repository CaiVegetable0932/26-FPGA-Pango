#ifndef TEST_MPU_HAL_H
#define TEST_MPU_HAL_H
#include <stdint.h>
typedef enum { HAL_OK, HAL_ERROR } HAL_StatusTypeDef;
typedef struct {
    unsigned ClockSpeed,DutyCycle,AddressingMode,DualAddressMode,GeneralCallMode,NoStretchMode;
} I2C_InitTypeDef;
typedef struct { unsigned Instance; I2C_InitTypeDef Init; } I2C_HandleTypeDef;
typedef struct { unsigned Pin,Mode,Speed; } GPIO_InitTypeDef;
#define GPIOB 1U
#define I2C1 1U
#define GPIO_PIN_6 64U
#define GPIO_PIN_7 128U
#define GPIO_MODE_AF_OD 1U
#define GPIO_SPEED_FREQ_HIGH 3U
#define I2C_DUTYCYCLE_2 2U
#define I2C_ADDRESSINGMODE_7BIT 7U
#define I2C_DUALADDRESS_DISABLE 0U
#define I2C_GENERALCALL_DISABLE 0U
#define I2C_NOSTRETCH_DISABLE 0U
#define I2C_MEMADD_SIZE_8BIT 1U
#define __HAL_RCC_GPIOB_CLK_ENABLE() ((void)0)
#define __HAL_RCC_I2C1_CLK_ENABLE() ((void)0)
void HAL_GPIO_Init(unsigned,GPIO_InitTypeDef *);
void HAL_Delay(uint32_t);
HAL_StatusTypeDef HAL_I2C_Init(I2C_HandleTypeDef *);
HAL_StatusTypeDef HAL_I2C_Mem_Read(I2C_HandleTypeDef *,uint16_t,uint16_t,uint16_t,uint8_t *,uint16_t,uint32_t);
HAL_StatusTypeDef HAL_I2C_Mem_Write(I2C_HandleTypeDef *,uint16_t,uint16_t,uint16_t,uint8_t *,uint16_t,uint32_t);
#endif
