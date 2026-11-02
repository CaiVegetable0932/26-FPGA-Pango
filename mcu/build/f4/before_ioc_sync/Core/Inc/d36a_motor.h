#ifndef D36A_MOTOR_H
#define D36A_MOTOR_H

#include "stm32f4xx_hal.h"

#ifdef __cplusplus
extern "C" {
#endif

#define D36A_MOTOR_COUNT          4U
#define D36A_FULL_STEPS_PER_REV   200U
#define D36A_MICROSTEPS           8U
#define D36A_PULSES_PER_REV       (D36A_FULL_STEPS_PER_REV * D36A_MICROSTEPS)
#define D36A_MAX_RPM              60

/*
 * motor: 1..4; rpm: -60..60 (sign selects DIR, zero stops and holds).
 * pulses: number of microsteps; zero means continuous rotation at nonzero rpm.
 * A finite move stops and holds after exactly 'pulses' STEP rising edges.
 * A new command replaces the old move at its next pulse boundary. Stop latency
 * is at most one old pulse period; no pulse is truncated on a direction change.
 * The first valid call initializes all four channels and waits 2 ms for wakeup.
 * Call from the main loop with interrupts enabled, after HAL/clock setup.
 * Returns HAL_ERROR for invalid arguments/context/unsupported timer clock.
 * GPIO and TIM2/3/4/5 are owned by d36a_motor.c; no separate init/poll API.
 */
HAL_StatusTypeDef D36A_Control(uint8_t motor, int16_t rpm, uint32_t pulses);

#ifdef __cplusplus
}
#endif

#endif
