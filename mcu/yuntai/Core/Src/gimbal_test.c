#include "gimbal_test.h"
#include "host_console.h"

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef enum {
    AXIS_IDLE = 0U,
    AXIS_CENTERING,
    AXIS_GO
} AxisPhase;

typedef struct {
    uint8_t id;
    uint16_t centerRaw;
    int32_t centerMilliDegrees;
    AxisPhase phase;
    uint16_t currentRaw;
    uint16_t targetRaw;
    int32_t targetMilliDegrees;
    uint8_t settleExtended;
    uint32_t deadline;
} Axis;

static Usart_DataTypeDef *bus;
static Axis axes[2] = {
    {.id = 1U, .centerRaw = GIMBAL_CENTER_PITCH_RAW,
     .centerMilliDegrees = GIMBAL_CENTER_PITCH_MDEG, .phase = AXIS_IDLE},
    {.id = 2U, .centerRaw = GIMBAL_CENTER_YAW_RAW,
     .centerMilliDegrees = GIMBAL_CENTER_YAW_MDEG, .phase = AXIS_IDLE}
};
static uint8_t gimbalReady;

static const char *AxisName(unsigned index)
{
    return index == 0U ? "pitch" : "yaw";
}

static void Reply(const char *format, ...)
{
    char text[320];
    va_list ap;
    va_start(ap, format);
    vsnprintf(text, sizeof(text), format, ap);
    va_end(ap);
    Host_Console_Write(text);
}

static uint8_t Busy(void)
{
    return axes[0].phase != AXIS_IDLE || axes[1].phase != AXIS_IDLE;
}

static uint16_t Word(const uint8_t *data)
{
    return ((uint16_t)data[0] << 8) | data[1];
}

static uint8_t Read(uint8_t id, uint8_t address, uint8_t *data, uint8_t length)
{
    uint8_t alarm = 0U;
    JOHO_STATUS status = USL_ReadRegister(bus, id, address, data, length, &alarm);
    if (status != JOHO_STATUS_SUCCESS || alarm != 0U) {
        Reply("[读取失败] 舵机ID=%u，通信状态=%u，报警=0x%02X。\r\n",
              id, status, alarm);
        return 0U;
    }
    return 1U;
}

static uint8_t ReadPosition(uint8_t id, uint16_t *position)
{
    uint8_t data[2];
    if (!position || !Read(id, 0x38U, data, 2U)) {
        return 0U;
    }
    *position = Word(data);
    if (*position > GIMBAL_POSITION_MAX) {
        Reply("[位置数据错误] 舵机ID=%u读回原始位置=%u，超出0..4095。\r\n",
              id, *position);
        return 0U;
    }
    return 1U;
}

static uint8_t ReadLimits(uint8_t id, uint16_t *minimum, uint16_t *maximum)
{
    uint8_t data[4];
    if (!minimum || !maximum || !Read(id, 0x09U, data, 4U)) {
        return 0U;
    }
    *minimum = Word(data);
    *maximum = Word(data + 2U);
    return 1U;
}

static uint16_t AngleToRaw(int32_t milliDegrees);

static uint8_t CheckGimbalLimits(unsigned index)
{
    Axis *axis = &axes[index];
    uint16_t minimum, maximum;
    uint16_t neededMinimum = AngleToRaw(axis->centerMilliDegrees -
                                        GIMBAL_ALLOWED_OFFSET_MDEG);
    uint16_t neededMaximum = AngleToRaw(axis->centerMilliDegrees +
                                        GIMBAL_ALLOWED_OFFSET_MDEG);
    if (!ReadLimits(axis->id, &minimum, &maximum)) return 0U;
    if (minimum > neededMinimum || maximum < neededMaximum ||
        minimum > maximum || maximum > GIMBAL_POSITION_MAX) {
        Reply("[限位不匹配] %s轴(ID=%u)设备限位raw=%u..%u，云台需要覆盖%u..%u；未修改EEPROM。\r\n",
              AxisName(index), axis->id, minimum, maximum,
              neededMinimum, neededMaximum);
        return 0U;
    }
    return 1U;
}

static uint8_t EnsurePositionMode(unsigned index)
{
    Axis *axis = &axes[index];
    uint8_t mode[1];

    if (!Read(axis->id, 0x1CU, mode, 1U)) {
        return 0U;
    }
    if (mode[0] == 1U || mode[0] == 0xFFU) {
        return 1U;
    }
    if (mode[0] != 0U) {
        Reply("[模式错误] %s轴(ID=%u)读回未知模式=%u。\r\n",
              AxisName(index), axis->id, mode[0]);
        return 0U;
    }

    /* A previous interrupted motor jog may leave the servo in motor mode. */
    {
        const uint8_t stopSpeed[4] = {0U, 0U, 0U, 0U};
        const uint8_t servoMode = 1U;
        if (USL_WriteRegister(bus, axis->id, 0x41U,
                              stopSpeed, sizeof(stopSpeed)) != JOHO_STATUS_SUCCESS ||
            USL_WriteRegister(bus, axis->id, 0x1CU,
                              &servoMode, 1U) != JOHO_STATUS_SUCCESS) {
            Reply("[模式恢复失败] %s轴(ID=%u)无法切回位置模式。\r\n",
                  AxisName(index), axis->id);
            return 0U;
        }
    }
    HAL_Delay(20U);
    if (!Read(axis->id, 0x1CU, mode, 1U) ||
        (mode[0] != 1U && mode[0] != 0xFFU)) {
        Reply("[模式恢复失败] %s轴(ID=%u)未确认位置模式。\r\n",
              AxisName(index), axis->id);
        return 0U;
    }
    Reply("[模式恢复] %s轴(ID=%u)已切回位置模式。\r\n",
          AxisName(index), axis->id);
    return 1U;
}

static uint8_t PrepareAxis(unsigned index)
{
    Axis *axis = &axes[index];
    if (!EnsurePositionMode(index) || !ReadPosition(axis->id, &axis->currentRaw)) {
        return 0U;
    }
    if (USL_MoveChecked(bus, axis->id, axis->currentRaw, 100U) != JOHO_STATUS_SUCCESS ||
        USL_TorqueChecked(bus, axis->id, 1U) != JOHO_STATUS_SUCCESS) {
        Reply("[发送失败] %s轴(ID=%u)保持当前位置或开启扭矩失败。\r\n",
              AxisName(index), axis->id);
        return 0U;
    }
    HAL_Delay(10U);
    {
        uint8_t torque[1];
        if (!Read(axis->id, 0x28U, torque, 1U) || torque[0] == 0U) {
            Reply("[扭矩未开启] %s轴(ID=%u)无法确认位置控制。\r\n",
                  AxisName(index), axis->id);
            return 0U;
        }
    }
    return 1U;
}

static uint8_t CheckDevices(void)
{
    for (unsigned i = 0U; i < 2U; i++) {
        uint8_t actual = 0U;
        uint8_t alarm = 0U;
        JOHO_STATUS status = USL_ReadRegister(bus, axes[i].id, 0x05U,
                                              &actual, 1U, &alarm);
        if (status != JOHO_STATUS_SUCCESS || alarm != 0U || actual != axes[i].id) {
            Reply("[启动核验失败] %s轴：期望ID=%u，读回ID=%u，通信状态=%u，报警=0x%02X。\r\n",
                  AxisName(i), axes[i].id, actual, status, alarm);
            gimbalReady = 0U;
            return 0U;
        }
        if (!EnsurePositionMode(i) || !CheckGimbalLimits(i)) {
            gimbalReady = 0U;
            return 0U;
        }
    }
    return 1U;
}

static uint16_t AngleToRaw(int32_t milliDegrees)
{
    uint32_t value = (uint32_t)milliDegrees * GIMBAL_POSITION_MAX;
    value = (value + GIMBAL_ANGLE_SCALE_MDEG / 2U) / GIMBAL_ANGLE_SCALE_MDEG;
    return value > GIMBAL_POSITION_MAX ? GIMBAL_POSITION_MAX : (uint16_t)value;
}

static int32_t OffsetToRawDelta(int32_t offsetMilliDegrees)
{
    uint32_t magnitude = (uint32_t)(offsetMilliDegrees < 0
                                    ? -offsetMilliDegrees : offsetMilliDegrees);
    int32_t delta = (int32_t)((magnitude * GIMBAL_POSITION_MAX +
                               GIMBAL_ANGLE_SCALE_MDEG / 2U) /
                              GIMBAL_ANGLE_SCALE_MDEG);
    return offsetMilliDegrees < 0 ? -delta : delta;
}

static int32_t RawToAngle(uint16_t raw)
{
    return (int32_t)(((uint32_t)raw * GIMBAL_ANGLE_SCALE_MDEG +
                       GIMBAL_POSITION_MAX / 2U) / GIMBAL_POSITION_MAX);
}

static void PrintAngle(int32_t milliDegrees, char *text, size_t size)
{
    int32_t absolute = milliDegrees < 0 ? -milliDegrees : milliDegrees;
    (void)snprintf(text, size, "%s%ld.%03ld°",
                   milliDegrees < 0 ? "-" : "+",
                   (long)(absolute / 1000L), (long)(absolute % 1000L));
}

static void StartCentering(void)
{
    for (unsigned i = 0U; i < 2U; i++) {
        Axis *axis = &axes[i];
        axis->targetRaw = axis->centerRaw;
        axis->targetMilliDegrees = axis->centerMilliDegrees;
        axis->settleExtended = 0U;
        axis->phase = AXIS_CENTERING;
        axis->deadline = HAL_GetTick() + GIMBAL_MOVE_TIME_MS + 500U;
        if (USL_MoveChecked(bus, axis->id, axis->targetRaw,
                            GIMBAL_MOVE_TIME_MS) != JOHO_STATUS_SUCCESS) {
            axis->phase = AXIS_IDLE;
            gimbalReady = 0U;
            Reply("[回正失败] %s轴(ID=%u)目标位置发送失败。\r\n",
                  AxisName(i), axis->id);
        }
    }
    if (Busy()) {
        Reply("[开始回正] 两个舵机已核验，正在回到正对角度 pitch=124.022°(raw=1881)、yaw=158.571°(raw=2405)。\r\n");
    }
}

static void ReadyCommand(void)
{
    if (Busy()) {
        Host_Console_Write("[命令错误] 舵机正在回正或运动，请等待完成。\r\n");
        return;
    }
    if (!CheckDevices() || !PrepareAxis(0U) || !PrepareAxis(1U)) {
        Host_Console_Write("[系统未就绪] 请检查舵机电源、ID和总线连接。\r\n");
        gimbalReady = 0U;
        return;
    }
    gimbalReady = 1U;
    StartCentering();
}

static void StartGo(int32_t pitchOffset, int32_t yawOffset)
{
    int32_t requested[2] = {pitchOffset, yawOffset};
    uint16_t target[2];

    if (!gimbalReady) {
        Host_Console_Write("[命令错误] 系统未就绪，请先发送 ready。\r\n");
        return;
    }
    if (Busy()) {
        Host_Console_Write("[命令错误] 舵机正在运动，请等待完成。\r\n");
        return;
    }
    for (unsigned i = 0U; i < 2U; i++) {
        int32_t delta = OffsetToRawDelta(requested[i]);
        int32_t rawTarget = (int32_t)axes[i].centerRaw + delta;
        if (requested[i] < -GIMBAL_ALLOWED_OFFSET_MDEG ||
            requested[i] > GIMBAL_ALLOWED_OFFSET_MDEG ||
            rawTarget < 0 || rawTarget > (int32_t)GIMBAL_POSITION_MAX) {
            Reply("[角度超限] %s轴参数必须在-60.000°..+60.000°范围内。\r\n",
                  AxisName(i));
            return;
        }
        target[i] = (uint16_t)rawTarget;
    }
    if (!PrepareAxis(0U) || !PrepareAxis(1U)) {
        return;
    }
    for (unsigned i = 0U; i < 2U; i++) {
        axes[i].targetRaw = target[i];
        axes[i].targetMilliDegrees = axes[i].centerMilliDegrees + requested[i];
        axes[i].settleExtended = 0U;
        axes[i].phase = AXIS_GO;
        axes[i].deadline = HAL_GetTick() + GIMBAL_MOVE_TIME_MS + 500U;
        if (USL_MoveChecked(bus, axes[i].id, target[i],
                            GIMBAL_MOVE_TIME_MS) != JOHO_STATUS_SUCCESS) {
            axes[i].phase = AXIS_IDLE;
            Reply("[运动失败] %s轴(ID=%u)目标位置发送失败。\r\n",
                  AxisName(i), axes[i].id);
        }
    }
    if (axes[0].phase == AXIS_GO && axes[1].phase == AXIS_GO) {
        char pitchText[24], yawText[24];
        PrintAngle(pitchOffset, pitchText, sizeof(pitchText));
        PrintAngle(yawOffset, yawText, sizeof(yawText));
        Reply("[云台运动] pitch相对正对=%s，yaw相对正对=%s；目标raw=%u/%u。\r\n",
              pitchText, yawText, target[0], target[1]);
    }
}

static void ReportBoth(void)
{
    uint16_t raw[2];
    int32_t angle[2];
    int32_t offset[2];
    char pitchAbsolute[24], pitchOffset[24];
    char yawAbsolute[24], yawOffset[24];
    if (!ReadPosition(axes[0].id, &raw[0]) || !ReadPosition(axes[1].id, &raw[1])) {
        return;
    }
    angle[0] = RawToAngle(raw[0]);
    angle[1] = RawToAngle(raw[1]);
    offset[0] = angle[0] - axes[0].centerMilliDegrees;
    offset[1] = angle[1] - axes[1].centerMilliDegrees;
    PrintAngle(angle[0], pitchAbsolute, sizeof(pitchAbsolute));
    PrintAngle(offset[0], pitchOffset, sizeof(pitchOffset));
    PrintAngle(angle[1], yawAbsolute, sizeof(yawAbsolute));
    PrintAngle(offset[1], yawOffset, sizeof(yawOffset));
    Reply("[当前角度] pitch绝对=%s，相对正对=%s（raw=%u）；yaw绝对=%s，相对正对=%s（raw=%u）。\r\n",
          pitchAbsolute, pitchOffset, raw[0],
          yawAbsolute, yawOffset, raw[1]);
}

static void PollAxis(unsigned index)
{
    Axis *axis = &axes[index];
    AxisPhase completed;
    uint16_t position;
    int32_t error;
    if (axis->phase == AXIS_IDLE || (int32_t)(HAL_GetTick() - axis->deadline) < 0) {
        return;
    }
    if (!ReadPosition(axis->id, &position)) {
        completed = axis->phase;
        axis->phase = AXIS_IDLE;
        if (completed == AXIS_CENTERING) gimbalReady = 0U;
        Reply("[运动失败] %s轴(ID=%u)无法读取当前位置。\r\n",
              AxisName(index), axis->id);
        return;
    }
    error = (int32_t)position - (int32_t)axis->targetRaw;
    if ((error < -(int32_t)GIMBAL_POSITION_TOLERANCE ||
         error > (int32_t)GIMBAL_POSITION_TOLERANCE) && !axis->settleExtended) {
        axis->settleExtended = 1U;
        axis->deadline = HAL_GetTick() + GIMBAL_SETTLE_TIME_MS;
        return;
    }
    if (error < -(int32_t)GIMBAL_POSITION_TOLERANCE ||
        error > (int32_t)GIMBAL_POSITION_TOLERANCE) {
        USL_MoveChecked(bus, axis->id, position, 100U);
        completed = axis->phase;
        axis->phase = AXIS_IDLE;
        if (completed == AXIS_CENTERING) gimbalReady = 0U;
        Reply("[未到位] %s轴(ID=%u)目标raw=%u，当前raw=%u。\r\n",
              AxisName(index), axis->id, axis->targetRaw, position);
        return;
    }
    completed = axis->phase;
    axis->phase = AXIS_IDLE;
    axis->settleExtended = 0U;
    if (completed == AXIS_CENTERING) {
        Reply("[回正完成] %s轴(ID=%u)已到正对角度。\r\n",
              AxisName(index), axis->id);
    } else {
        Reply("[运动完成] %s轴(ID=%u)当前绝对角度=%ld.%03ld°。\r\n",
              AxisName(index), axis->id,
              (long)(axis->targetMilliDegrees / 1000L),
              (long)(axis->targetMilliDegrees % 1000L));
    }
}

static uint8_t ParseOffset(const char *text, int32_t *milliDegrees)
{
    int32_t whole = 0;
    uint32_t fraction = 0U;
    uint32_t scale = 100U;
    unsigned digits = 0U;
    int32_t sign = 1;
    const char *cursor = text;

    if (!text || !milliDegrees || strlen(text) > 9U) {
        return 0U;
    }
    if (*cursor == '+' || *cursor == '-') {
        if (*cursor == '-') sign = -1;
        cursor++;
    }
    if (*cursor < '0' || *cursor > '9') return 0U;
    while (*cursor >= '0' && *cursor <= '9') {
        whole = whole * 10 + (*cursor - '0');
        if (whole > (int32_t)(GIMBAL_ALLOWED_OFFSET_MDEG / 1000L)) return 0U;
        cursor++;
    }
    if (*cursor == '.') {
        cursor++;
        while (*cursor >= '0' && *cursor <= '9' && digits < 3U) {
            fraction += (uint32_t)(*cursor - '0') * scale;
            scale /= 10U;
            digits++;
            cursor++;
        }
        if (digits == 0U) return 0U;
    }
    if (*cursor != '\0' ||
        (whole == (int32_t)(GIMBAL_ALLOWED_OFFSET_MDEG / 1000L) &&
         fraction != 0U)) {
        return 0U;
    }
    *milliDegrees = sign * (whole * 1000L + (int32_t)fraction);
    return 1U;
}

static void Command(char *line)
{
    char *argv[4];
    unsigned argc = 0U;
    char *token = strtok(line, " \t");
    while (token && argc < 4U) {
        argv[argc++] = token;
        token = strtok(NULL, " \t");
    }
    if (!argc) return;
    if (!strcmp(argv[0], "ready") && argc == 1U) {
        ReadyCommand();
    } else if (!strcmp(argv[0], "get") && argc == 1U) {
        ReportBoth();
    } else if (!strcmp(argv[0], "go") && argc == 3U) {
        int32_t pitch, yaw;
        if (ParseOffset(argv[1], &pitch) && ParseOffset(argv[2], &yaw)) {
            StartGo(pitch, yaw);
        } else {
            Host_Console_Write("[命令错误] go参数必须是-60..+60°的相对正对角度。\r\n");
        }
    } else {
        Host_Console_Write("[命令错误] 仅支持：ready、go a1 a2、get。\r\n");
    }
}

void Gimbal_Test_Init(Usart_DataTypeDef *servoBus)
{
    bus = servoBus;
    axes[0].id = 1U;
    axes[1].id = 2U;
    axes[0].phase = axes[1].phase = AXIS_IDLE;
    gimbalReady = 0U;
    Host_Console_Write("[启动完成] pitch=ID1，yaw=ID2；发送ready核验并回正。\r\n");
    Host_Console_Write("[标定参数] 270°舵机；正对角度 pitch=124.022°（raw=1881），yaw=158.571°（raw=2405）；go范围为正对角度±60°。\r\n");
}

void Gimbal_Test_Poll(void)
{
    char line[HOST_CONSOLE_LINE_SIZE];
    if (Host_Console_ReadLine(line, sizeof(line))) {
        Command(line);
    }
    PollAxis(0U);
    PollAxis(1U);
}
