#ifndef GIMBAL_TEST_H
#define GIMBAL_TEST_H

#include "uart_servo_lite.h"

/* 命令入口有两处：
 *   - F4 代理帧（f1_link.c 的 F1_READY / F1_GO / F1_ZERO），这是当前唯一生效的入口；
 *   - 旧的文本控制台（gimbal_test.c 的 Command()），因未绑定串口而不生效，
 *     见 host_console.h 顶部说明。
 * 本文件的 Reply(...) 诊断文本在当前构建里不会出现在任何链路上，状态以 F1_STATE 为准。 */

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
/* Arrival tolerance in raw counts. The bus servos repeat to roughly +-20
 * counts (~1.3 deg) of the commanded target, so 12 was stricter than the
 * hardware can deliver; 24 counts = 1.58 deg. It must match
 * POSE_CENTER_TOL_RAW in firmware/common/pose.c. */
/* 2026-10-22：24 -> 32 计数。实测该总线舵机回正后停在离中心 12~31 计数之间
 * （yaw 轴最坏 31 计数 = 2.0°），24 计数会随机判"未到位"并进入 failed。
 * 居中容差只影响机械对中精度；姿态零位用的是实际 raw 值，因此跟踪精度不受影响。 */
#define GIMBAL_POSITION_TOLERANCE          32U
/* 2026-10-22：云台"运动到位"单独用一个更小的容差。
 * 原来运动到位也复用 24 计数，导致 1.6°(=24 计数) 的定位命令被判定"已在容差内"
 * 而直接完成、舵机不动作。运动容差取 16 计数(约 1.05°)，使 1.6° 的命令必须真正移动；
 * 舵机 ±20 计数的重复精度影响由 settleExtended / GIMBAL_SETTLE_TIME_MS 吸收。
 * 居中判定（本文件的 GIMBAL_POSITION_TOLERANCE、pose.c 的 POSE_CENTER_TOL_RAW）
 * 仍保持 24 且二者一致，避免 /home 与 /posezero 变得不稳定。 */
#define GIMBAL_MOTION_TOLERANCE            16U

void Gimbal_Test_Init(Usart_DataTypeDef *bus);
void Gimbal_Test_Poll(void);
/* Optional pose observer keeps the vendor control and arrival tests intact. */
typedef void (*GimbalFeedback)(unsigned axis, uint16_t raw, uint8_t valid);
void Gimbal_SetFeedback(GimbalFeedback feedback);
void Gimbal_SetPoseReady(uint8_t ready);
uint8_t Gimbal_State(void); /* 0 idle, 1 move, 2 centering, 5 failed */
/* 2026-10-22 诊断：最近一次"系统就绪/回正准备"失败的步骤号（0=无失败）。
 * 10=读ID 11=进位置模式 12=限位检查 20=进位置模式 21=读位置 22=锁位 23=开扭矩 24=回读扭矩 */
uint8_t Gimbal_LastFailStep(void);
uint8_t Gimbal_Ready(void);
uint8_t Gimbal_Go(int32_t pitch, int32_t yaw);
/* Local fault recovery only; there is no serial all-axis stop command. */
uint8_t Gimbal_CancelMotion(void);
void Gimbal_ReadFeedback(void);

#endif
