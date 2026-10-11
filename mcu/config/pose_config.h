#ifndef MCU_POSE_CONFIG_H
#define MCU_POSE_CONFIG_H
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
