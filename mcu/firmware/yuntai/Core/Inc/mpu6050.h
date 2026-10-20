#ifndef MPU6050_H
#define MPU6050_H
#include "pose.h"
/* I2C1 PB6/PB7, AD0 low. Poll DATA_READY when an interrupt wire is absent.
 *
 * 本驱动当前不参与 F1 固件构建（2026-10-20 起放弃 MPU6050 姿态融合，
 * pitch/yaw 只用舵机位置反馈）。文件与其宿主机测试 tests/test_mpu6050.c
 * 保留，便于将来恢复；启用时需要同时：
 *   1. 在 CMakeLists.txt 重新加入 Core/Src/mpu6050.c；
 *   2. 在 f1_link.c 恢复 MPU6050_Init()/MPU6050_Poll() 调用；
 *   3. 让 pose_calibrate() 回到 sensor_valid 分支（该分支仍完整保留）。 */
int MPU6050_Init(void);
void MPU6050_Poll(Pose *pose, uint64_t tick_us);
#endif
