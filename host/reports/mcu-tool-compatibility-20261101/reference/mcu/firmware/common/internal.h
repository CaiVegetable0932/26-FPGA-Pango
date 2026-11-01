#ifndef MCU_INTERNAL_H
#define MCU_INTERNAL_H
#include "wire.h"
/* F4-F1 uses the same CRC envelope; internal command IDs are separate. */
#define F1_INFO 0x20U
#define F1_READY 0x21U
#define F1_GO 0x22U
/* 0x23 is retired; do not reuse it for a different command. */
#define F1_ZERO 0x24U
#define F1_STATE 0xa1U
#define F1_REPLY 0xa0U
#define F1_STATE_BYTES 128U
/* State: boot8, sample4, phase1, zero1, home1, source1, ticks(3x8),
 * fused(2x4), servo(2x4), raw(2x2), imu32, errors8, zeros8, biases12,
 * config4, reserved12. Internal times remain F1 times until mapped by F4.
 * The IMU fields are published as 0 because pose fusion was dropped
 * (2026-10-20): 76..89 accel/gyro/temperature, 90 sensor_valid, 92 i2c_errors. */
#endif
