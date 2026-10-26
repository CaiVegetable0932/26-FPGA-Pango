#include "gimbal_test.h"
#include "host_console.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static uint32_t now;
static uint16_t position[251];
static uint16_t minLimit[251];
static uint16_t maxLimit[251];
static uint8_t servoMode[251];
static uint8_t torqueEnabled[251];
static uint8_t alarm[251];
static unsigned writes[251];
static uint16_t lastTarget[251];
static uint16_t lastInterval[251];
static uint8_t failure;
static char command[64];
static char output[8192];
static Usart_DataTypeDef bus;

uint32_t HAL_GetTick(void) { return now; }
void HAL_Delay(uint32_t ms) { now += ms; }
void Host_Console_Write(const char *s)
{
    strncat(output, s, sizeof(output) - strlen(output) - 1U);
}
uint8_t Host_Console_ReadLine(char *s, uint16_t capacity)
{
    if (!command[0]) return 0U;
    snprintf(s, capacity, "%s", command);
    command[0] = 0;
    return 1U;
}

JOHO_STATUS USL_ReadRegister(Usart_DataTypeDef *u, uint8_t id, uint8_t addr,
                             uint8_t *data, uint8_t length, uint8_t *status)
{
    (void)u;
    memset(data, 0, length);
    *status = alarm[id];
    if (failure) return JOHO_STATUS_TIMEOUT;
    switch (addr) {
        case 0x05: data[0] = id; break;
        case 0x1C: data[0] = servoMode[id]; break;
        case 0x28: data[0] = torqueEnabled[id]; break;
        case 0x09:
            data[0] = (uint8_t)(minLimit[id] >> 8); data[1] = (uint8_t)minLimit[id];
            data[2] = (uint8_t)(maxLimit[id] >> 8); data[3] = (uint8_t)maxLimit[id];
            break;
        case 0x38:
            data[0] = (uint8_t)(position[id] >> 8); data[1] = (uint8_t)position[id];
            break;
        default: break;
    }
    return JOHO_STATUS_SUCCESS;
}

JOHO_STATUS USL_WriteRegister(Usart_DataTypeDef *u, uint8_t id, uint8_t addr,
                              const uint8_t *data, uint8_t length)
{
    (void)u;
    if (addr == 0x09U && length == 4U) {
        minLimit[id] = ((uint16_t)data[0] << 8) | data[1];
        maxLimit[id] = ((uint16_t)data[2] << 8) | data[3];
    } else if (addr == 0x1CU && length == 1U) {
        servoMode[id] = data[0];
    } else if (addr == 0x41U && length == 4U) {
        /* accepted stop frame */
    } else {
        return JOHO_STATUS_FAIL;
    }
    return JOHO_STATUS_SUCCESS;
}

JOHO_STATUS USL_MoveChecked(Usart_DataTypeDef *u, uint8_t id,
                            uint16_t pos, uint16_t ms)
{
    (void)u;
    writes[id]++;
    lastTarget[id] = pos;
    lastInterval[id] = ms;
    position[id] = pos;
    return JOHO_STATUS_SUCCESS;
}

JOHO_STATUS USL_TorqueChecked(Usart_DataTypeDef *u, uint8_t id, uint8_t enable)
{
    (void)u;
    torqueEnabled[id] = enable;
    return JOHO_STATUS_SUCCESS;
}

static void Send(const char *text)
{
    snprintf(command, sizeof(command), "%s", text);
    Gimbal_Test_Poll();
}

static void Advance(uint32_t ms)
{
    now += ms;
    Gimbal_Test_Poll();
}

int main(void)
{
    for (unsigned id = 1U; id <= 2U; id++) {
        minLimit[id] = 100U;
        maxLimit[id] = 4000U;
        servoMode[id] = 1U;
    }
    position[1] = 1000U;
    position[2] = 2000U;

    Gimbal_Test_Init(&bus);
    assert(writes[1] == 0U && writes[2] == 0U);
    Send("ready");
    assert(minLimit[1] == 100U && maxLimit[1] == 4000U);
    assert(minLimit[2] == 100U && maxLimit[2] == 4000U);
    assert(torqueEnabled[1] == 1U && torqueEnabled[2] == 1U);
    assert(lastTarget[1] == 1881U);
    assert(lastTarget[2] == 2405U);
    Advance(3000U);
    assert(strstr(output, "[回正完成] pitch轴(ID=1)"));
    assert(strstr(output, "[回正完成] yaw轴(ID=2)"));

    Send("get");
    assert(strstr(output, "pitch绝对=+124.022°，相对正对=+0.000°"));
    assert(strstr(output, "yaw绝对=+158.571°，相对正对=+0.000°"));

    Send("go -60 -60");
    assert(lastTarget[1] == 971U && lastTarget[2] == 1495U);
    assert(lastInterval[1] == GIMBAL_MOVE_TIME_MS);
    Advance(3000U);
    assert(strstr(output, "[运动完成] pitch轴(ID=1)"));
    assert(strstr(output, "[运动完成] yaw轴(ID=2)"));

    unsigned before = writes[1];
    Send("go 61 0");
    assert(writes[1] == before);
    Send("go 0 -61");
    assert(writes[1] == before);
    Send("go -60 60");
    assert(lastTarget[1] == 971U && lastTarget[2] == 3315U);
    Advance(3000U);
    assert(strstr(output, "[运动完成] pitch轴(ID=1)"));
    assert(strstr(output, "[运动完成] yaw轴(ID=2)"));
    before = writes[1];
    Send("go 0 -61");
    assert(writes[1] == before);
    Send("move 1 2");
    Send("get 1");
    assert(writes[1] == before);

    servoMode[1] = 0U;
    Send("go 0 0");
    assert(servoMode[1] == 1U);
    Advance(3000U);
    assert(strstr(output, "[模式恢复] pitch轴(ID=1)"));

    alarm[1] = 8U;
    before = writes[1];
    Send("ready");
    assert(writes[1] == before);
    alarm[1] = 0U;
    failure = 1U;
    Send("get");
    failure = 0U;

    puts("PASS: ready centering, calibrated 270-degree mapping, go range, get, mode recovery and errors");
    return 0;
}
