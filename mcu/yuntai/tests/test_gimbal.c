#include "gimbal_test.h"
#include "host_console.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static uint32_t now;
static uint16_t position[251];
static uint16_t limit = 4095;
static unsigned writes[251];
static unsigned released[251];
static uint8_t failure, alarm, motorMode;
static char command[64];
static char output[4096];
static Usart_DataTypeDef bus;

uint32_t HAL_GetTick(void) { return now; }
void HAL_Delay(uint32_t ms) { now += ms; }
void Host_Console_Write(const char *s) { strncat(output, s, sizeof(output)-strlen(output)-1U); }
uint8_t Host_Console_ReadLine(char *s, uint16_t capacity)
{
    if (!command[0]) return 0;
    snprintf(s, capacity, "%s", command);
    command[0] = 0;
    return 1;
}
JOHO_STATUS USL_ReadRegister(Usart_DataTypeDef *u, uint8_t id, uint8_t addr,
                            uint8_t *data, uint8_t length, uint8_t *status)
{
    (void)u; memset(data, 0, length); *status = alarm;
    if (failure) return JOHO_STATUS_TIMEOUT;
    switch (addr) {
        case 0x05: data[0] = id; break;
        case 0x1C: data[0] = !motorMode; break;
        case 0x38: data[0] = position[id] >> 8; data[1] = position[id]; break;
        case 0x09: data[2] = limit >> 8; data[3] = limit; break;
        case 0x28: data[0] = 1; break;
    }
    return JOHO_STATUS_SUCCESS;
}
JOHO_STATUS USL_MoveChecked(Usart_DataTypeDef *u, uint8_t id, uint16_t pos, uint16_t ms)
{ (void)u; (void)ms; writes[id]++; position[id] = pos; return 0; }
JOHO_STATUS USL_TorqueChecked(Usart_DataTypeDef *u, uint8_t id, uint8_t enable)
{ (void)u; if (!enable) released[id]++; return 0; }
JOHO_STATUS USL_ChangeId(Usart_DataTypeDef *u, uint8_t old, uint8_t new)
{ (void)u; (void)old; (void)new; assert(!"unexpected ID write"); return 1; }

static void Send(const char *s)
{ snprintf(command, sizeof(command), "%s", s); Gimbal_Test_Poll(); }
static void Advance(void) { now += 3000U; Gimbal_Test_Poll(); }

int main(void)
{
    position[1] = 2000; position[2] = 1800;
    Gimbal_Test_Init(&bus);
    assert(writes[1] == 0 && writes[2] == 0);
    Send("move 1");
    assert(position[1] == 2000 + GIMBAL_TEST_STEP && writes[2] == 0);
    Send("move 1"); /* busy request cannot restart the origin */
    assert(writes[1] == 2);
    Send("move 2");
    assert(position[2] == 1800 + GIMBAL_TEST_STEP);
    Advance();
    assert(position[1] == 2000 && position[2] == 1800);
    Advance();
    assert(strstr(output, "DONE pitch axis=1") && strstr(output, "DONE yaw axis=2"));
    unsigned before = writes[1];
    Send("move 0"); Send("move 3"); Send("move 1 extra");
    Send("move 9999999999999999999");
    assert(writes[1] == before);
    limit = 2100; Send("move 1"); assert(writes[1] == before); limit = 4095;
    motorMode = 1; Send("move 1"); assert(writes[1] == before); motorMode = 0;
    alarm = 8; Send("move 1"); assert(writes[1] == before); alarm = 0;
    failure = 1; Send("move 1"); assert(writes[1] == before); failure = 0;
    Send("move 1"); Send("ov 1");
    before = writes[1]; Advance(); assert(writes[1] == before);
    Send("move 1"); failure = 1; Advance(); failure = 0;
    assert(released[1] == 1);
    Send("setid 1 2"); /* isolated acknowledgement is mandatory */
    Send("map 1 2"); /* reject duplicate mapping */
    Send("map 1 3"); Send("move 1");
    assert(writes[3] == 2);
    puts("PASS: separate IDs, concurrent move/return, busy, limits, malformed commands, mode/alarm/timeout, ov, ID guard, mapping");
    return 0;
}
