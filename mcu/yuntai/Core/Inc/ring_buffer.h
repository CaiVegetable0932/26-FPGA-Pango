#ifndef __RING_BUFFER_H
#define __RING_BUFFER_H

#include "stm32f1xx.h"
#include <stdint.h>

typedef struct
{
    uint8_t *buffer;
    volatile uint16_t head;
    volatile uint16_t tail;
    uint16_t size;
} RingBufferTypeDef;

void RingBuffer_Init(RingBufferTypeDef *ringBuf, uint16_t capacity,
                     uint8_t *buffer);
void RingBuffer_Reset(RingBufferTypeDef *ringBuf);
uint16_t RingBuffer_GetCapacity(RingBufferTypeDef *ringBuf);
uint16_t RingBuffer_GetByteUsed(RingBufferTypeDef *ringBuf);
uint16_t RingBuffer_GetByteFree(RingBufferTypeDef *ringBuf);
uint8_t RingBuffer_IsEmpty(RingBufferTypeDef *ringBuf);
uint8_t RingBuffer_IsFull(RingBufferTypeDef *ringBuf);
uint8_t RingBuffer_GetValueByIndex(RingBufferTypeDef *ringBuf,
                                   uint16_t index);
uint8_t RingBuffer_Pop(RingBufferTypeDef *ringBuf);
uint8_t RingBuffer_ReadByte(RingBufferTypeDef *ringBuf);
void RingBuffer_ReadByteArray(RingBufferTypeDef *ringBuf, uint8_t *dest,
                              uint16_t size);
int16_t RingBuffer_ReadShort(RingBufferTypeDef *ringBuf);
uint16_t RingBuffer_ReadUShort(RingBufferTypeDef *ringBuf);
int32_t RingBuffer_ReadLong(RingBufferTypeDef *ringBuf);
uint32_t RingBuffer_ReadULong(RingBufferTypeDef *ringBuf);
float RingBuffer_ReadFloat(RingBufferTypeDef *ringBuf);
void RingBuffer_Push(RingBufferTypeDef *ringBuf, uint8_t value);
void RingBuffer_WriteByte(RingBufferTypeDef *ringBuf, uint8_t value);
void RingBuffer_WriteByteArray(RingBufferTypeDef *ringBuf, uint8_t *src,
                               uint16_t size);
void RingBuffer_WriteShort(RingBufferTypeDef *ringBuf, int16_t value);
void RingBuffer_WriteUShort(RingBufferTypeDef *ringBuf, uint16_t value);
void RingBuffer_WriteLong(RingBufferTypeDef *ringBuf, int32_t value);
void RingBuffer_WriteULong(RingBufferTypeDef *ringBuf, uint32_t value);
void RingBuffer_WriteFloat(RingBufferTypeDef *ringBuf, float value);
uint8_t RingBuffer_GetChecksum(RingBufferTypeDef *ringBuf);

#endif /* __RING_BUFFER_H */
