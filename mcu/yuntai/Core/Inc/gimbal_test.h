#ifndef GIMBAL_TEST_H
#define GIMBAL_TEST_H

#include "uart_servo_lite.h"

/* Nominal travel assumption for this test; verify the actual servo/model. */
#define GIMBAL_TRAVEL_DEGREES 270U
#define GIMBAL_POSITION_MAX 4095U
#define GIMBAL_ANGLE_SCALE_MDEG (GIMBAL_TRAVEL_DEGREES * 1000U)
#define GIMBAL_TEST_STEP ((GIMBAL_POSITION_MAX * 10U + GIMBAL_TRAVEL_DEGREES / 2U) / GIMBAL_TRAVEL_DEGREES)
#define GIMBAL_TEST_MOVE_MS 2000U

void Gimbal_Test_Init(Usart_DataTypeDef *bus);
void Gimbal_Test_Poll(void);

#endif
