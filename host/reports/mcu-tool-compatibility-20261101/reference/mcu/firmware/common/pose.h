#ifndef MCU_POSE_H
#define MCU_POSE_H
#include <stdint.h>

/* Six-axis complementary attitude and a feedback-confirmed zero procedure. */
typedef struct {
    float roll, pitch, yaw, bias[3], q_bi[4];
    float zero_pitch, zero_yaw;
    uint64_t imu_us, servo_us[2], settle_us;
    int16_t accel[3], gyro[3], temperature;
    uint32_t sample_seq, i2c_errors, missed, stable_samples;
    double bias_sum[3];
    int32_t servo[2], angle[2];
    uint16_t servo_raw[2], servo_weight, imu_weight;
    uint32_t disagreement_mdeg, stale_us;
    uint8_t sensor_valid, servo_valid, zero_valid, home_confirmed, settling, source;
} Pose;
void pose_init(Pose *p);
void pose_sample(Pose *p, const int16_t accel[3], const int16_t gyro[3], int16_t temperature, uint64_t tick);
void pose_servo(Pose *p, unsigned axis, uint16_t raw, uint64_t tick, int valid);
void pose_begin_home(Pose *p);
void pose_home_confirmed(Pose *p, uint64_t tick);
void pose_abort(Pose *p);
int pose_calibrate(Pose *p, uint64_t tick);
void pose_fuse(Pose *p, uint64_t tick);
int32_t pose_delta(int32_t angle);
#endif
