#include "wire.h"
#include <string.h>

uint16_t wire_u16(const uint8_t *p) { return (uint16_t)(p[0] | (uint16_t)p[1] << 8); }
uint32_t wire_u32(const uint8_t *p) { return wire_u16(p) | (uint32_t)wire_u16(p+2) << 16; }
uint64_t wire_u64(const uint8_t *p) { return wire_u32(p) | (uint64_t)wire_u32(p+4) << 32; }
void wire_put16(uint8_t *p, uint16_t n) { p[0]=(uint8_t)n; p[1]=(uint8_t)(n>>8); }
void wire_put32(uint8_t *p, uint32_t n) { wire_put16(p,(uint16_t)n); wire_put16(p+2,(uint16_t)(n>>16)); }
void wire_put64(uint8_t *p, uint64_t n) { wire_put32(p,(uint32_t)n); wire_put32(p+4,(uint32_t)(n>>32)); }
void wire_count(uint32_t *n) { if (*n != UINT32_MAX) ++*n; }

uint16_t wire_crc(const uint8_t *p, size_t n)
{
    uint16_t crc=0xffffU;
    while (n--) {
        crc ^= (uint16_t)*p++ << 8;
        for (unsigned j=0; j<8; ++j)
            crc=(uint16_t)((crc & 0x8000U) ? ((uint32_t)crc<<1)^0x1021U : (uint32_t)crc<<1);
    }
    return crc;
}

size_t wire_frame(uint8_t *out, uint8_t cmd, uint16_t seq, const uint8_t *p, uint16_t n)
{
    if (n>WIRE_MAX_PAYLOAD) return 0;
    out[0]=0x55; out[1]=0xaa; out[2]=WIRE_VERSION; out[3]=cmd;
    wire_put16(out+4,seq); wire_put16(out+6,n);
    if (n) memcpy(out+8,p,n);
    wire_put16(out+8+n,wire_crc(out+2,6+n));
    return n+10U;
}

void wire_init(WireParser *p, uint16_t timeout, WireReceive cb, void *context)
{
    memset(p,0,sizeof(*p)); p->timeout_ms=timeout; p->receive=cb; p->context=context;
}

static void discard(WireParser *p, unsigned n)
{
    p->used=(uint16_t)(p->used-n);
    memmove(p->bytes,p->bytes+n,p->used);
    memmove(p->ticks,p->ticks+n,p->used*sizeof(p->ticks[0]));
    if (p->used) p->start_us+=(uint32_t)(p->ticks[0]-(uint32_t)p->start_us);
}

/* Drop one candidate byte on corruption so a nested later frame survives. */
static void parse(WireParser *p, uint64_t now)
{
    while (p->used) {
        if (p->bytes[0]!=0x55 || (p->used>1 && p->bytes[1]!=0xaa)) { discard(p,1); continue; }
        if (p->used<8) return;
        uint16_t n=wire_u16(p->bytes+6);
        if (p->bytes[2]!=WIRE_VERSION || n>WIRE_MAX_PAYLOAD) {
            wire_count(&p->length_errors); discard(p,1); continue;
        }
        if (p->used<n+10U) return;
        if (wire_u16(p->bytes+8+n)!=wire_crc(p->bytes+2,6+n)) {
            wire_count(&p->crc_errors); discard(p,1); continue;
        }
        p->receive(p->context,p->bytes[3],wire_u16(p->bytes+4),p->bytes+8,n,now);
        discard(p,n+10U);
    }
}

void wire_poll(WireParser *p, uint64_t now)
{
    while (p->used && now-p->start_us >= (uint64_t)p->timeout_ms*1000U) {
        wire_count(&p->timeouts); discard(p,1);
        parse(p,now);
    }
}
void wire_feed(WireParser *p, uint8_t byte, uint64_t now)
{
    wire_poll(p,now);
    if (!p->used) p->start_us=now;
    p->ticks[p->used]=(uint32_t)now; p->bytes[p->used++]=byte;
    parse(p,now);
}
