#include "gimbal_test.h"
#include "host_console.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint8_t id;
    uint8_t phase; /* 0 idle, 1 outward, 2 return, 3 relative jog */
    uint8_t settleExtended;
    uint16_t targetTolerance;
    uint16_t origin;
    uint16_t target;
    uint32_t deadline;
    int32_t requestedMilliDegrees;
} Axis;

static Usart_DataTypeDef *bus;
static Axis axes[2] = {{.id = 1U}, {.id = 2U}};
static uint8_t gimbalReady;

static const char *AxisName(unsigned index)
{
    return index == 0U ? "pitch" : "yaw";
}

static void Reply(const char *format, ...)
{
    char text[192];
    va_list ap;
    va_start(ap, format);
    vsnprintf(text, sizeof(text), format, ap);
    va_end(ap);
    Host_Console_Write(text);
}

static uint8_t Busy(void)
{
    return axes[0].phase || axes[1].phase;
}

static uint8_t CheckReady(void)
{
    uint8_t found[2] = {0U, 0U};
    for (unsigned i = 0U; i < 2U; i++) {
        uint8_t actual = 0U, alarm = 0U;
        JOHO_STATUS status = USL_ReadRegister(bus, axes[i].id, 0x05U,
                                              &actual, 1U, &alarm);
        if (status == JOHO_STATUS_SUCCESS && alarm == 0U && actual == axes[i].id) {
            found[i] = 1U;
        } else {
            Reply("SETUP %s expected_id=%u actual_id=%u comm=%u alarm=0x%02X\r\n",
                  AxisName(i), axes[i].id, actual, status, alarm);
        }
    }
    gimbalReady = found[0] && found[1];
    if (gimbalReady) {
        Reply("READY pitch=axis1/id%u yaw=axis2/id%u; move 1|2 available\r\n",
              axes[0].id, axes[1].id);
    } else {
        Host_Console_Write("NOT READY; fix servo IDs/power/bus, then send ready or scan 1 2\r\n");
    }
    return gimbalReady;
}

static uint8_t Read(uint8_t id, uint8_t address, uint8_t *data, uint8_t length)
{
    uint8_t alarm = 0U;
    JOHO_STATUS status = USL_ReadRegister(bus, id, address, data, length, &alarm);
    if (status != JOHO_STATUS_SUCCESS || alarm != 0U) {
        Reply("ERR id=%u comm=%u alarm=0x%02X\r\n", id, status, alarm);
        return 0U;
    }
    return 1U;
}

static uint16_t Word(const uint8_t *data)
{
    return ((uint16_t)data[0] << 8) | data[1];
}

static uint8_t Position(uint8_t id, uint16_t *position)
{
    uint8_t data[2];
    if (!Read(id, 0x38U, data, 2U)) {
        return 0U;
    }
    *position = Word(data);
    if (*position > GIMBAL_POSITION_MAX) {
        Reply("ERR id=%u position=%u invalid\r\n", id, *position);
        return 0U;
    }
    return 1U;
}

static void Report(uint8_t id)
{
    uint16_t position;
    if (Position(id, &position)) {
        uint32_t tenths = ((uint32_t)position * GIMBAL_TRAVEL_DEGREES * 10U
                          + GIMBAL_POSITION_MAX / 2U) / GIMBAL_POSITION_MAX;
        Reply("POS id=%u raw=%u angle=%lu.%lu deg (nominal)\r\n", id, position,
              (unsigned long)(tenths / 10U), (unsigned long)(tenths % 10U));
    }
}

static void StartMove(unsigned index)
{
    Axis *axis = &axes[index - 1U];
    uint8_t data[4];
    uint16_t min, max;
    if (!gimbalReady) {
        Host_Console_Write("ERR system not ready; send ready after checking servo IDs\r\n");
        return;
    }
    if (axis->phase) {
        Reply("ERR %s axis=%u busy\r\n", AxisName(index - 1U), index);
        return;
    }
    if (!Read(axis->id, 0x1CU, data, 1U)) {
        return;
    }
    if (data[0] != 1U && data[0] != 0xFFU) {
        Reply("ERR %s axis=%u motor mode; use servo position mode\r\n", AxisName(index - 1U), index);
        return;
    }
    if (!Position(axis->id, &axis->origin) || !Read(axis->id, 0x09U, data, 4U)) {
        return;
    }
    min = Word(data);
    max = Word(data + 2);
    if (min > max || max > GIMBAL_POSITION_MAX || axis->origin < min ||
        (uint32_t)axis->origin + GIMBAL_TEST_STEP > max) {
        Reply("ERR %s axis=%u +10deg outside device limits; raw=%u min=%u max=%u\r\n",
              AxisName(index - 1U), index, axis->origin, min, max);
        return;
    }
    /* Hold the measured position before enabling torque: no startup target jump. */
    if (USL_MoveChecked(bus, axis->id, axis->origin, GIMBAL_TEST_MOVE_MS) != 0U ||
        USL_TorqueChecked(bus, axis->id, 1U) != 0U) {
        Reply("ERR %s axis=%u transmit failed\r\n", AxisName(index - 1U), index);
        return;
    }
    HAL_Delay(10U);
    if (!Read(axis->id, 0x28U, data, 1U) || data[0] == 0U) {
        Reply("ERR %s axis=%u torque not enabled\r\n", AxisName(index - 1U), index);
        return;
    }
    axis->target = axis->origin + GIMBAL_TEST_STEP;
    if (USL_MoveChecked(bus, axis->id, axis->target, GIMBAL_TEST_MOVE_MS) != 0U) {
        Reply("ERR %s axis=%u transmit failed\r\n", AxisName(index - 1U), index);
        return;
    }
    axis->phase = 1U;
    axis->settleExtended = 0U;
    axis->targetTolerance = 12U;
    axis->deadline = HAL_GetTick() + GIMBAL_TEST_MOVE_MS + 500U;
    Reply("MOVE %s axis=%u id=%u raw=%u -> %u (+10deg), then return\r\n",
          AxisName(index - 1U), index, axis->id, axis->origin, axis->target);
}

static void StartJog(unsigned index, int32_t angleMilliDegrees)
{
    Axis *axis = &axes[index - 1U];
    uint8_t data[4];
    uint16_t min, max;
    uint32_t magnitude = (uint32_t)(angleMilliDegrees < 0
                                  ? -angleMilliDegrees : angleMilliDegrees);
    uint32_t deltaCounts = (magnitude * GIMBAL_POSITION_MAX
                          + GIMBAL_ANGLE_SCALE_MDEG / 2U) / GIMBAL_ANGLE_SCALE_MDEG;
    int32_t target;
    uint32_t interval;

    if (!gimbalReady) {
        Host_Console_Write("ERR system not ready; send ready first\r\n");
        return;
    }
    if (axis->phase) {
        Reply("ERR %s axis=%u busy\r\n", AxisName(index - 1U), index);
        return;
    }
    if (!Read(axis->id, 0x1CU, data, 1U)) {
        return;
    }
    if (data[0] != 1U && data[0] != 0xFFU) {
        Reply("ERR %s axis=%u motor mode; use servo position mode\r\n",
              AxisName(index - 1U), index);
        return;
    }
    if (!Position(axis->id, &axis->origin) || !Read(axis->id, 0x09U, data, 4U)) {
        return;
    }
    min = Word(data);
    max = Word(data + 2U);
    if (deltaCounts == 0U) {
        Reply("ERR %s requested angle is below one raw-position count\r\n",
              AxisName(index - 1U));
        return;
    }
    target = (int32_t)axis->origin +
             (angleMilliDegrees < 0 ? -(int32_t)deltaCounts : (int32_t)deltaCounts);
    if (min > max || max > GIMBAL_POSITION_MAX || target < min || target > max) {
        Reply("ERR %s delta exceeds raw limits; raw=%u target=%ld min=%u max=%u\r\n",
              AxisName(index - 1U), axis->origin, (long)target, min, max);
        return;
    }

    /* Establish the measured position before torque-on to avoid a target jump. */
    if (USL_MoveChecked(bus, axis->id, axis->origin, GIMBAL_TEST_MOVE_MS) != 0U ||
        USL_TorqueChecked(bus, axis->id, 1U) != 0U) {
        Reply("ERR %s hold/torque transmit failed\r\n", AxisName(index - 1U));
        return;
    }
    HAL_Delay(10U);
    if (!Read(axis->id, 0x28U, data, 1U) || data[0] == 0U) {
        Reply("ERR %s torque not enabled\r\n", AxisName(index - 1U));
        return;
    }

    /* Keep tiny increments slow enough to observe during manual calibration. */
    interval = (magnitude * 200U + 500U) / 1000U;
    if (interval < 250U) interval = 250U;
    if (interval > 60000U) interval = 60000U;
    axis->target = (uint16_t)target;
    if (USL_MoveChecked(bus, axis->id, axis->target, (uint16_t)interval) != 0U) {
        Reply("ERR %s jog transmit failed\r\n", AxisName(index - 1U));
        return;
    }
    axis->phase = 3U;
    axis->settleExtended = 0U;
    axis->targetTolerance = 1U;
    axis->requestedMilliDegrees = angleMilliDegrees;
    axis->deadline = HAL_GetTick() + interval + 500U;
    Reply("JOG %s axis=%u id=%u delta=%c%lu.%03lu deg raw=%u -> %u interval=%lu ms\r\n",
          AxisName(index - 1U), index, axis->id,
          angleMilliDegrees < 0 ? '-' : '+',
          (unsigned long)(magnitude / 1000U), (unsigned long)(magnitude % 1000U),
          axis->origin, axis->target, (unsigned long)interval);
}

static void PollMove(unsigned index)
{
    Axis *axis = &axes[index];
    uint16_t position;
    if (!axis->phase || (int32_t)(HAL_GetTick() - axis->deadline) < 0) {
        return;
    }
    if (!Position(axis->id, &position)) {
        USL_TorqueChecked(bus, axis->id, 0U);
        axis->phase = 0U;
        Reply("ERR %s axis=%u feedback lost; torque-off sent\r\n",
              AxisName(index), index + 1U);
        return;
    }
    int32_t error = (int32_t)position - axis->target;
    int32_t tolerance = axis->targetTolerance;
    if ((error < -tolerance || error > tolerance) && !axis->settleExtended) {
        axis->settleExtended = 1U;
        axis->deadline = HAL_GetTick() + 1000U;
        Reply("WAIT %s axis=%u target=%u actual=%u; one extra second to settle\r\n",
              AxisName(index), index + 1U, axis->target, position);
        return;
    }
    if (axis->phase == 3U) {
        axis->phase = 0U;
        if (error < -tolerance || error > tolerance) {
            Reply("WARN %s jog target=%u actual=%u; read current position with get %u\r\n",
                  AxisName(index), axis->target, position, axis->id);
        } else {
            uint32_t angle = (uint32_t)(axis->requestedMilliDegrees < 0
                                      ? -axis->requestedMilliDegrees
                                      : axis->requestedMilliDegrees);
            Reply("DONE %s axis=%u id=%u delta=%c%lu.%03lu deg raw=%u\r\n",
                  AxisName(index), index + 1U, axis->id,
                  axis->requestedMilliDegrees < 0 ? '-' : '+',
                  (unsigned long)(angle / 1000U), (unsigned long)(angle % 1000U), position);
        }
        return;
    }
    if (axis->phase == 1U) {
        if (error < -tolerance || error > tolerance) {
            Reply("WARN %s forward target=%u actual=%u; returning to origin\r\n",
                  AxisName(index), axis->target, position);
        }
        axis->target = axis->origin;
        axis->settleExtended = 0U;
        if (USL_MoveChecked(bus, axis->id, axis->target, GIMBAL_TEST_MOVE_MS) != 0U) {
            axis->phase = 0U;
            Reply("ERR %s axis=%u return transmit failed\r\n",
                  AxisName(index), index + 1U);
            return;
        }
        axis->phase = 2U;
        axis->deadline = HAL_GetTick() + GIMBAL_TEST_MOVE_MS + 500U;
        Reply("RETURN %s axis=%u id=%u (-10deg)\r\n",
              AxisName(index), index + 1U, axis->id);
        return;
    }
    if (error < -tolerance || error > tolerance) {
        USL_MoveChecked(bus, axis->id, position, GIMBAL_TEST_MOVE_MS);
        axis->phase = 0U;
        Reply("ERR %s axis=%u return target=%u actual=%u; holding actual position\r\n",
              AxisName(index), index + 1U, axis->target, position);
        return;
    }
    axis->phase = 0U;
    axis->settleExtended = 0U;
    Reply("DONE %s axis=%u id=%u raw=%u\r\n",
          AxisName(index), index + 1U, axis->id, position);
}

static uint8_t Number(const char *s, unsigned *number)
{
    char *end;
    if (!s || *s < '0' || *s > '9') {
        return 0U;
    }
    if (strlen(s) > 3U) {
        return 0U;
    }
    unsigned long value = strtoul(s, &end, 10);
    if (*end || value > 250U) {
        return 0U;
    }
    *number = (unsigned)value;
    return 1U;
}

static uint8_t ParseAngleMilliDegrees(const char *s, int32_t *angle)
{
    int32_t sign = 1;
    uint32_t whole = 0U, fraction = 0U, fractionScale = 100U;
    unsigned fractionDigits = 0U;
    if (!s || !angle || strlen(s) > 8U) return 0U;
    if (*s == '+' || *s == '-') {
        if (*s == '-') sign = -1;
        s++;
    }
    if (*s < '0' || *s > '9') return 0U;
    while (*s >= '0' && *s <= '9') {
        whole = whole * 10U + (uint32_t)(*s - '0');
        if (whole > GIMBAL_TRAVEL_DEGREES) return 0U;
        s++;
    }
    if (*s == '.') {
        s++;
        while (*s >= '0' && *s <= '9' && fractionDigits < 3U) {
            fraction += (uint32_t)(*s - '0') * fractionScale;
            fractionScale /= 10U;
            fractionDigits++;
            s++;
        }
        if (!fractionDigits) return 0U;
    }
    if (*s != '\0' || (whole == GIMBAL_TRAVEL_DEGREES && fraction != 0U)) return 0U;
    uint32_t milliDegrees = whole * 1000U + fraction;
    if (milliDegrees == 0U) return 0U;
    *angle = sign * (int32_t)milliDegrees;
    return 1U;
}

static void Help(void)
{
    Host_Console_Write("help | status | ready | scan [first last] | ping ID | get ID\r\n"
                       "move AXIS : 10deg out-and-return test; move AXIS DEG : relative jog\r\n"
                       "Example: move 1 0.1 / move 2 -0.1; map AXIS ID | setid OLD NEW isolated\r\n"
                       "ov [AXIS] : hold current position; torque ID 0|1\r\n"
                       "Use get ID after a jog to read raw position. End each command with CR/LF.\r\n");
}

static void Command(char *line)
{
    char *argv[5];
    unsigned argc = 0U, a = 0U, b = 0U;
    char *token = strtok(line, " \t");
    while (token && argc < 5U) {
        argv[argc++] = token;
        token = strtok(NULL, " \t");
    }
    if (!argc) {
        return;
    }
    if (!strcmp(argv[0], "help") && argc == 1U) {
        Help();
    } else if (!strcmp(argv[0], "status") && argc == 1U) {
        Reply("STATUS ready=%u pitch(axis1)=id%u phase%u yaw(axis2)=id%u phase%u\r\n",
              gimbalReady, axes[0].id, axes[0].phase, axes[1].id, axes[1].phase);
    } else if (!strcmp(argv[0], "ready") && argc == 1U) {
        CheckReady();
    } else if (!strcmp(argv[0], "move")) {
        if (argc == 2U && Number(argv[1], &a) && a >= 1U && a <= 2U) {
            StartMove(a);
        } else if (argc == 3U && Number(argv[1], &a) && a >= 1U && a <= 2U) {
            int32_t angleMilliDegrees;
            if (ParseAngleMilliDegrees(argv[2], &angleMilliDegrees)) {
                StartJog(a, angleMilliDegrees);
            } else {
                Host_Console_Write("ERR angle format/range; use e.g. move 1 -0.1\r\n");
            }
        } else {
            Host_Console_Write("ERR move syntax; use move AXIS [SIGNED_DEGREES]\r\n");
        }
    } else if (!strcmp(argv[0], "get") && argc == 2U &&
               Number(argv[1], &a) && a >= 1U) {
        Report((uint8_t)a);
    } else if (!strcmp(argv[0], "ping") && argc == 2U &&
               Number(argv[1], &a) && a >= 1U) {
        uint8_t id;
        if (Read((uint8_t)a, 0x05U, &id, 1U)) {
            Reply("PING requested=%u actual=%u\r\n", a, id);
        }
    } else if (!strcmp(argv[0], "scan") && (argc == 1U || argc == 3U)) {
        a = 1U;
        b = 250U;
        if ((argc == 3U && (!Number(argv[1], &a) || !Number(argv[2], &b))) ||
            a < 1U || a > b || Busy()) {
            Host_Console_Write("ERR scan range/busy\r\n");
            return;
        }
        Reply("SCAN %u..%u (up to 27s); wait for SCAN DONE\r\n", a, b);
        unsigned count = 0U;
        for (unsigned id = a; id <= b; id++) {
            uint8_t readback, alarm;
            if (USL_ReadRegister(bus, (uint8_t)id, 0x05U, &readback, 1U, &alarm) == 0U &&
                readback == id) {
                Reply("FOUND id=%u alarm=0x%02X\r\n", id, alarm);
                count++;
            }
        }
        Reply("SCAN DONE found=%u (duplicate IDs cannot be detected reliably)\r\n", count);
    } else if (!strcmp(argv[0], "map") && argc == 3U &&
               Number(argv[1], &a) && a >= 1U && a <= 2U &&
               Number(argv[2], &b) && b >= 1U) {
        if (Busy() || axes[2U - a].id == b) {
            Host_Console_Write("ERR map busy/duplicate ID\r\n");
            return;
        }
        axes[a - 1U].id = (uint8_t)b;
        Reply("MAP %s axis=%u id=%u (RAM only)\r\n", AxisName(a - 1U), a, b);
        CheckReady();
    } else if (!strcmp(argv[0], "setid") && argc == 4U &&
               Number(argv[1], &a) && a >= 1U && Number(argv[2], &b) && b >= 1U &&
               !strcmp(argv[3], "isolated")) {
        if (Busy()) {
            Host_Console_Write("ERR setid busy\r\n");
            return;
        }
        uint8_t data;
        if (!Read((uint8_t)a, 0x05U, &data, 1U) || data != a) {
            return;
        }
        uint8_t alarm;
        if (a != b && USL_ReadRegister(bus, (uint8_t)b, 0x05U, &data, 1U, &alarm) == 0U) {
            Host_Console_Write("ERR new ID already responds\r\n");
            return;
        }
        JOHO_STATUS result = USL_ChangeId(bus, (uint8_t)a, (uint8_t)b);
        Reply("SETID old=%u new=%u comm=%u; power-cycle and ping new ID\r\n", a, b, result);
        if (result == JOHO_STATUS_SUCCESS) {
            CheckReady();
        }
    } else if (!strcmp(argv[0], "ov") && (argc == 1U ||
               (argc == 2U && Number(argv[1], &a) && a >= 1U && a <= 2U))) {
        for (unsigned i = 0U; i < 2U; i++) {
            if (argc == 2U && a != i + 1U) {
                continue;
            }
            axes[i].phase = 0U;
            uint16_t position;
            if (Position(axes[i].id, &position)) {
                JOHO_STATUS result = USL_MoveChecked(bus, axes[i].id, position, 100U);
                Reply("HOLD %s axis=%u id=%u raw=%u comm=%u\r\n",
                      AxisName(i), i + 1U, axes[i].id, position, result);
            } else {
                USL_TorqueChecked(bus, axes[i].id, 0U);
            }
        }
    } else if (!strcmp(argv[0], "torque") && argc == 3U &&
               Number(argv[1], &a) && a >= 1U && Number(argv[2], &b) && b <= 1U) {
        if (Busy()) {
            Host_Console_Write("ERR torque busy; use ov first\r\n");
            return;
        }
        uint16_t position;
        if (b && (!Position((uint8_t)a, &position) ||
                  USL_MoveChecked(bus, (uint8_t)a, position, 100U) != 0U)) {
            return;
        }
        Reply("TORQUE id=%u enable=%u comm=%u\r\n", a, b,
              USL_TorqueChecked(bus, (uint8_t)a, (uint8_t)b));
    } else {
        Host_Console_Write("ERR command/arguments; use help\r\n");
    }
}

void Gimbal_Test_Init(Usart_DataTypeDef *servoBus)
{
    bus = servoBus;
    axes[0].id = 1U;
    axes[1].id = 2U;
    axes[0].phase = axes[1].phase = 0U;
    axes[0].settleExtended = axes[1].settleExtended = 0U;
    Host_Console_Write("SETUP checking saved servo IDs; no ID write or motion on boot\r\n");
    Reply("Mapping fixed: pitch axis1=id1, yaw axis2=id2. Scale assumption: %udeg / %u counts; test step=%u counts\r\n",
          GIMBAL_TRAVEL_DEGREES, GIMBAL_POSITION_MAX, GIMBAL_TEST_STEP);
    Help();
    CheckReady();
}

void Gimbal_Test_Poll(void)
{
    char line[HOST_CONSOLE_LINE_SIZE];
    if (Host_Console_ReadLine(line, sizeof(line))) {
        Command(line);
    }
    PollMove(0U);
    PollMove(1U);
}
