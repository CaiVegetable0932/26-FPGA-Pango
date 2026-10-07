#ifndef GIMBAL_TEST_H
#define GIMBAL_TEST_H

#include "uart_servo_lite.h"

/* JOHO position raw 0..4095 maps to the calibrated 270 degree range. */
#define GIMBAL_TRAVEL_DEGREES              270U
#define GIMBAL_POSITION_MAX                4095U
#define GIMBAL_ANGLE_SCALE_MDEG            (GIMBAL_TRAVEL_DEGREES * 1000U)
#define GIMBAL_CENTER_PITCH_MDEG           124022L
#define GIMBAL_CENTER_YAW_MDEG             158571L
#define GIMBAL_ALLOWED_OFFSET_MDEG         60000L
#define GIMBAL_CENTER_PITCH_RAW            1881U
#define GIMBAL_CENTER_YAW_RAW              2405U
#define GIMBAL_MOVE_TIME_MS                2000U
#define GIMBAL_SETTLE_TIME_MS              1000U
#define GIMBAL_POSITION_TOLERANCE          12U

void Gimbal_Test_Init(Usart_DataTypeDef *bus);
void Gimbal_Test_Poll(void);

#endif
