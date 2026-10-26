#ifndef MCU_POSE_CONFIG_H
#define MCU_POSE_CONFIG_H
/* 2026-10-20 起 F1 放弃 MPU6050 姿态融合，pitch/yaw 只用舵机位置反馈。
 * 下列 IMU 相关项（四元数、权重、稳定角速度阈值）仍被 pose.c 的保留分支引用，
 * 因此不删除；当前固件不会走到该分支，实际生效的只有 POSE_WAIT_US、
 * POSE_STALE_US 和舵机中心容差（pose.c 内的 POSE_CENTER_TOL_RAW=24）。 */
/* Bench defaults, not a claim of measured precision or mounting direction. */
#define POSE_SERVO_WEIGHT 9U
#define POSE_IMU_WEIGHT 1U
#define POSE_DISAGREEMENT_MDEG 3000U
#define POSE_STALE_US 20000U
#define POSE_WAIT_US 5000000ULL
#define POSE_STABLE_RATE_DPS 2.0f
#define POSE_CONFIG_VERIFIED 0U
#define POSE_Q_BI_W 1.0f
#define POSE_Q_BI_X 0.0f
#define POSE_Q_BI_Y 0.0f
#define POSE_Q_BI_Z 0.0f
#if POSE_SERVO_WEIGHT <= POSE_IMU_WEIGHT || POSE_IMU_WEIGHT == 0
#error Servo feedback weight must exceed the nonzero IMU weight
#endif
#endif
