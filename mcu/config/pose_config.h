#ifndef MCU_POSE_CONFIG_H
#define MCU_POSE_CONFIG_H
/* 2026-10-20 起 F1 放弃 MPU6050 姿态融合，pitch/yaw 只用舵机位置反馈。
 * 下列 IMU 相关项（四元数、权重、稳定角速度阈值）仍被 pose.c 的保留分支引用，
 * 因此不删除；当前固件不会走到该分支，实际生效的只有 POSE_WAIT_US、
 * POSE_STALE_US 和舵机中心容差（pose.c 内的 POSE_CENTER_TOL_RAW=12）。 */
/* Bench defaults, not a claim of measured precision or mounting direction. */
#define POSE_SERVO_WEIGHT 9U
#define POSE_IMU_WEIGHT 1U
#define POSE_DISAGREEMENT_MDEG 3000U
/* 2026-10-22：20 ms -> 60 ms。F1 每 10 ms 读一次舵机反馈，两个轴先后读取，
 * 再叠加 F4/F1 之间的时间戳映射误差，最旧的那个轴实测在 19 ms 上下波动，
 * 20 ms 门限会随机越界，把正常的云台定位命令误判成 fault=5(DRIVER) 并取消任务。
 * 60 ms 仍远小于舵机实际失联的判别尺度，用于识别真正过期的反馈。
 *
 * 2026-10-22 再次调整：60 ms -> 250 ms。云台运动中 F1 要访问舵机总线，偶发一次
 * 读超时就会让发布间隔超过 60 ms，实测在第二段 ±20° 运动开始约 0.36 s 时
 * 触发 fault=5 并取消任务（而 F1 的回执是 result=1 已接受、动作实际完成了）。
 * 250 ms 仍是 5 ms 发布周期的 50 倍；真正断线时 f1_online（50 ms 未收帧）
 * 会先一步报 fault=8，因此这里不会掩盖真实故障。 */
#define POSE_STALE_US 250000U
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
