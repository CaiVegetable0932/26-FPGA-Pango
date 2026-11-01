/* Execute the unmodified 22452f36 gateway with a healthy simulated F1/axes.
 * Only hardware/time are stubbed; frame parsing, requests, events, query limits,
 * delayed zero responses and event overflow all run the actual firmware code. */
#include "reference/mcu/firmware/longmenjia/Core/Src/f4_link.c"
#include <assert.h>

UART_HandleTypeDef huart3,huart4,huart6;
AuditRegisters audit_uart;
uint32_t F4_PinMask;
static uint64_t audit_now=1000000;
static uint8_t output[131072];
static unsigned output_size;
uint64_t board_us(void) { return audit_now; }
uint64_t board_boot_id(void) { return 11; }
uint64_t board_device_id(void) { return 42; }
void MX_Extra_UART_Init(void) {}
void board_port_init(BoardPort *p,UART_HandleTypeDef *u,WireReceive cb,void *c,uint16_t t)
{ (void)u; memset(p,0,sizeof(*p)); wire_init(&p->parser,t,cb,c); }
void board_port_init_dma(BoardPort *p,UART_HandleTypeDef *u,WireReceive cb,void *c,uint16_t t)
{ board_port_init(p,u,cb,c,t); }
void board_port_rx(BoardPort *p,UART_HandleTypeDef *u) { (void)p;(void)u; }
void board_port_error(BoardPort *p,UART_HandleTypeDef *u) { (void)p;(void)u; }
void board_port_tx_done(BoardPort *p,UART_HandleTypeDef *u) { (void)p;(void)u; }
void board_port_poll(BoardPort *p) { (void)p; }
int board_port_send(BoardPort *p,uint8_t cmd,uint16_t seq,const uint8_t *b,uint16_t n,int s)
{
    (void)s;
    if(p==&links[0].port) {
        assert(output_size+n+10<sizeof(output));
        output_size+=(unsigned)wire_frame(output+output_size,cmd,seq,b,n);
    }
    return 1;
}
/* Stationary valid axes and fresh calibrated servo feedback isolate PC logic. */
void F4_AxesSnapshot(int32_t p[3],uint32_t l[3],uint8_t *b,uint8_t *v)
{ memset(p,0,12);for(unsigned i=0;i<3;i++)l[i]=1600;*b=0;*v=7; }
uint8_t F4_AxesMove(uint8_t m,const int32_t t[3],const uint16_t r[3])
{ (void)m;(void)t;(void)r; return 1; }
void F4_AxesStop(void) {}
uint8_t F4_AxesResult(uint8_t m) { (void)m;return 0; }
uint8_t F4_ManualZero(uint8_t m) { (void)m;return 0; }
void F4_Legacy(char *l,char *out,unsigned c)
{ (void)l;snprintf(out,c,"ok\r\n"); }
static void healthy_f1(void)
{
    f1_boot=22; f1_received=f1_state_received=audit_now; f1_offset=0;
    f1_data[12]=0;f1_data[13]=1;f1_data[14]=1;f1_data[15]=10;
    wire_put64(f1_data+24,audit_now);wire_put64(f1_data+32,audit_now);
    wire_put32(f1_data+40,1234);wire_put32(f1_data+44,(uint32_t)-5678);
    pending.active=0;
}
void audit_init(void) { F4_Link_Init();healthy_f1();make_snapshot(audit_now); }
void audit_tick(unsigned us) { audit_now+=us;healthy_f1();F4_Link_Poll(); }
/* Expose the same clock to Python so lease/query timing is deterministic. */
uint64_t audit_time(void) { return audit_now; }
void audit_write(const uint8_t *p,unsigned n)
{ for(unsigned i=0;i<n;i++)wire_feed(&links[0].port.parser,p[i],audit_now); }
unsigned audit_read(uint8_t *p,unsigned n)
{
    if(n>output_size)n=output_size;
    memcpy(p,output,n);memmove(output,output+n,output_size-n);output_size-=n;return n;
}
unsigned audit_fault(void) { return fault; }
unsigned audit_event_count(void) { return event_id; }
unsigned audit_ack(void) { return links[0].ack; }
unsigned audit_zero_pending(void) { return zero_pending; }
/* Exercise the exact event queue boundary independently of motion timing. */
void audit_emit_event(void) { if(!latest_motion)latest_motion=1;event(1,24,2,0); }
