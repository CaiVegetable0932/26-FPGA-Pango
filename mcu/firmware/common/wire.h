#ifndef MCU_WIRE_H
#define MCU_WIRE_H
#include <stddef.h>
#include <stdint.h>

/* Explicit little-endian serialization shared by both MCUs. No packed structs. */
#define WIRE_MAX_PAYLOAD 1024U
#define WIRE_MAX_FRAME (WIRE_MAX_PAYLOAD + 10U)
#define WIRE_VERSION 2U
typedef void (*WireReceive)(void *, uint8_t, uint16_t, const uint8_t *, uint16_t, uint64_t);
typedef struct {
    uint8_t bytes[WIRE_MAX_FRAME];
    uint16_t used, timeout_ms;
    uint64_t start_us;
    uint32_t ticks[WIRE_MAX_FRAME];
    uint32_t crc_errors, length_errors, timeouts;
    WireReceive receive;
    void *context;
} WireParser;
uint16_t wire_u16(const uint8_t *p);
uint32_t wire_u32(const uint8_t *p);
uint64_t wire_u64(const uint8_t *p);
void wire_put16(uint8_t *p, uint16_t n);
void wire_put32(uint8_t *p, uint32_t n);
void wire_put64(uint8_t *p, uint64_t n);
uint16_t wire_crc(const uint8_t *p, size_t n);
size_t wire_frame(uint8_t *out, uint8_t cmd, uint16_t seq, const uint8_t *p, uint16_t n);
void wire_init(WireParser *p, uint16_t timeout_ms, WireReceive receive, void *context);
void wire_feed(WireParser *p, uint8_t byte, uint64_t tick_us);
void wire_poll(WireParser *p, uint64_t tick_us);
void wire_count(uint32_t *counter);
#endif
