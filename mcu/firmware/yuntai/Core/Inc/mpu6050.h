#ifndef MPU6050_H
#define MPU6050_H
#include "pose.h"
/* I2C1 PB6/PB7, AD0 low. Poll DATA_READY when an interrupt wire is absent. */
int MPU6050_Init(void);
void MPU6050_Poll(Pose *pose, uint64_t tick_us);
#endif
