#include "uart_servo_lite.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static UART_HandleTypeDef uart;
static Usart_DataTypeDef bus;
static uint8_t *rx;
static uint8_t transmitted[128];
static uint16_t transmitted_length;
static uint8_t reply[128];
static unsigned reply_length;
static uint32_t tick;
static HAL_StatusTypeDef transmit_status;

void HAL_UART_RxCpltCallback(UART_HandleTypeDef *huart);
void Host_Console_RxCpltCallback(UART_HandleTypeDef *huart) { (void)huart; }
void Host_Console_ErrorCallback(UART_HandleTypeDef *huart) { (void)huart; }
uint32_t HAL_GetTick(void) { return tick++; }
void HAL_Delay(uint32_t ms) { tick += ms; }
HAL_StatusTypeDef HAL_UART_Receive_IT(UART_HandleTypeDef *huart,
                                    uint8_t *data, uint16_t length)
{
    assert(huart == &uart && length == 1U);
    rx = data;
    return HAL_OK;
}
HAL_StatusTypeDef HAL_UART_Transmit(UART_HandleTypeDef *huart, uint8_t *data,
                                  uint16_t length, uint32_t timeout)
{
    (void)timeout;
    assert(huart == &uart && length <= sizeof(transmitted));
    memcpy(transmitted, data, length);
    transmitted_length = length;
    if (transmit_status == HAL_OK && data[4] == CMDType_Read) {
        for (unsigned i = 0U; i < reply_length; i++) {
            *rx = reply[i];
            HAL_UART_RxCpltCallback(huart);
        }
        reply_length = 0U;
    }
    return transmit_status;
}

static void Expect(const uint8_t *data, unsigned size)
{
    assert(transmitted_length == size);
    assert(memcmp(transmitted, data, size) == 0);
}

static void Response(uint8_t id, uint8_t alarm, const uint8_t *data, unsigned size)
{
    unsigned start = reply_length;
    reply[reply_length++] = 0xFF;
    reply[reply_length++] = 0xF5;
    reply[reply_length++] = id;
    reply[reply_length++] = (uint8_t)(size + 2U);
    reply[reply_length++] = alarm;
    for (unsigned i = 0U; i < size; i++) reply[reply_length++] = data[i];
    unsigned sum = 0U;
    for (unsigned i = start + 2U; i < reply_length; i++) sum += reply[i];
    reply[reply_length++] = (uint8_t)~sum;
}

int main(void)
{
    Servo_UART_Init(&bus, &uart);
    const uint8_t move[] = {0xFF,0xFF,1,7,3,0x2A,7,0xD0,3,0xE8,8};
    assert(USL_MoveChecked(&bus, 1U, 2000U, 1000U) == JOHO_STATUS_SUCCESS);
    Expect(move, sizeof(move));
    const uint8_t torque[] = {0xFF,0xFF,2,4,3,0x28,1,0xCD};
    assert(USL_TorqueChecked(&bus, 2U, 1U) == JOHO_STATUS_SUCCESS);
    Expect(torque, sizeof(torque));
    const uint8_t fullRangeData[] = {0x00,0x00,0x0F,0xFF};
    const uint8_t fullRange[] = {0xFF,0xFF,1,7,3,0x09,0x00,0x00,0x0F,0xFF,0xDD};
    assert(USL_WriteRegister(&bus, 1U, 0x09U, fullRangeData, sizeof(fullRangeData)) == JOHO_STATUS_SUCCESS);
    Expect(fullRange, sizeof(fullRange));
    const uint8_t motorModeData[] = {0x00};
    const uint8_t motorModeFrame[] = {0xFF,0xFF,1,4,3,0x1C,0x00,0xDB};
    assert(USL_WriteRegister(&bus, 1U, 0x1CU, motorModeData, sizeof(motorModeData)) == JOHO_STATUS_SUCCESS);
    Expect(motorModeFrame, sizeof(motorModeFrame));
    const uint8_t directionFrame[] = {0xFF,0xFF,1,4,3,0x1D,0x00,0xDA};
    assert(USL_WriteRegister(&bus, 1U, 0x1DU, motorModeData, sizeof(motorModeData)) == JOHO_STATUS_SUCCESS);
    Expect(directionFrame, sizeof(directionFrame));
    const uint8_t speedData[] = {0x00,0x14,0x00,0x00};
    const uint8_t speedFrame[] = {0xFF,0xFF,1,7,3,0x41,0x00,0x14,0x00,0x00,0x9F};
    assert(USL_WriteRegister(&bus, 1U, 0x41U, speedData, sizeof(speedData)) == JOHO_STATUS_SUCCESS);
    Expect(speedFrame, sizeof(speedFrame));

    uint8_t data[2], alarm = 0U;
    const uint8_t position[] = {7, 0xD0};
    Response(1U, 0U, position, sizeof(position));
    assert(USL_ReadRegister(&bus, 1U, 0x38U, data, 2U, &alarm) == JOHO_STATUS_SUCCESS);
    const uint8_t read[] = {0xFF,0xFF,1,4,2,0x38,2,0xBE};
    Expect(read, sizeof(read));
    assert(memcmp(data, position, 2U) == 0 && alarm == 0U);

    /* An old write ACK and another ID must not be mistaken for position. */
    Response(1U, 0U, NULL, 0U);
    Response(2U, 0U, position, 2U);
    Response(1U, 8U, position, 2U);
    assert(USL_ReadRegister(&bus, 1U, 0x38U, data, 2U, &alarm) == JOHO_STATUS_SUCCESS);
    assert(alarm == 8U);

    Response(1U, 0U, position, 2U);
    reply[reply_length - 1U] ^= 1U;
    assert(USL_ReadRegister(&bus, 1U, 0x38U, data, 2U, &alarm) == JOHO_STATUS_CHECKSUM_ERROR);
    reply[0] = 0xFF; reply[1] = 0xF5; reply[2] = 1U; reply[3] = 0U;
    reply_length = 4U;
    assert(USL_ReadRegister(&bus, 1U, 0x38U, data, 2U, &alarm) == JOHO_STATUS_SIZE_TOO_BIG);
    assert(USL_ReadRegister(&bus, 1U, 0x38U, data, 2U, &alarm) == JOHO_STATUS_TIMEOUT);
    const uint8_t new_id = 2U;
    Response(2U, 0U, &new_id, 1U);
    assert(USL_ChangeId(&bus, 1U, 2U) == JOHO_STATUS_SUCCESS);
    Response(2U, 8U, &new_id, 1U);
    assert(USL_ChangeId(&bus, 1U, 2U) == JOHO_STATUS_FAIL);
    const uint8_t wrong_id = 3U;
    Response(2U, 0U, &wrong_id, 1U);
    assert(USL_ChangeId(&bus, 1U, 2U) == JOHO_STATUS_ID_NOT_MATCH);
    transmit_status = HAL_ERROR;
    assert(USL_ReadRegister(&bus, 1U, 0x38U, data, 2U, &alarm) == JOHO_STATUS_FAIL);
    assert(USL_MoveChecked(&bus, 1U, 2000U, 1000U) == JOHO_STATUS_FAIL);
    assert(USL_TorqueChecked(&bus, 1U, 1U) == JOHO_STATUS_FAIL);
    assert(USL_TorqueChecked(&bus, 254U, 1U) == JOHO_STATUS_FAIL);
    puts("PASS: golden UART frames, checksum, big endian, motor mode direction/speed frames, ACK/ID filtering, alarm, malformed size, timeout, ID readback and TX failure");
    return 0;
}
