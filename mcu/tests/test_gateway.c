#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../firmware/longmenjia/Core/Src/f4_link.c"

UART_HandleTypeDef huart1,huart3,huart6;
static uint64_t now=1000000;
static uint8_t axis_busy,axis_valid=7;
static unsigned moves,stops,sends,internal_sends;
static uint8_t last_cmd,last_data[300];
static uint16_t last_size;
uint64_t board_us(void) { return now; }
uint64_t board_boot_id(void) { return 11; }
uint64_t board_device_id(void) { return 42; }
void MX_Extra_UART_Init(void) { }
void board_port_init(BoardPort *p,UART_HandleTypeDef *u,WireReceive cb,void *c,uint16_t t)
{ (void)u; memset(p,0,sizeof(*p)); wire_init(&p->parser,t,cb,c); }
void board_port_rx(BoardPort *p,UART_HandleTypeDef *u) { (void)p;(void)u; }
void board_port_error(BoardPort *p,UART_HandleTypeDef *u) { (void)p;(void)u; }
void board_port_tx_done(BoardPort *p,UART_HandleTypeDef *u) { (void)p;(void)u; }
void board_port_poll(BoardPort *p) { (void)p; }
int board_port_send(BoardPort *p,uint8_t cmd,uint16_t seq,const uint8_t *b,uint16_t n,int s)
{ (void)seq;(void)s;last_cmd=cmd;last_size=n;if(n)memcpy(last_data,b,n);++sends;
  if(p==&f1){assert(cmd!=0x23);++internal_sends;}return 1; }
void F4_AxesSnapshot(int32_t p[3],uint32_t l[3],uint8_t *b,uint8_t *v)
{ memset(p,0,12);for(unsigned i=0;i<3;i++)l[i]=1600;*b=axis_busy;*v=axis_valid; }
uint8_t F4_AxesMove(uint8_t m,const int32_t t[3],const uint16_t r[3])
{ (void)t;(void)r; axis_busy|=m; ++moves; return 1; }
void F4_AxesStop(void) { axis_busy=0; ++stops; }
uint8_t F4_AxesResult(uint8_t mask) { return (axis_busy&mask)?1:0; }
uint8_t F4_ManualZero(uint8_t m) { axis_valid|=m;return 0; }
void F4_Legacy(char *l,char *out,unsigned c)
{ if(!strcmp(l,"stop 1"))axis_busy&=(uint8_t)~1U;snprintf(out,c,"ok\r\n"); }
static void request(unsigned link,uint8_t cmd,uint16_t seq,uint8_t *p,uint16_t n)
{ receive(&links[link],cmd,seq,p,n,now); }
static void context(uint8_t *p,unsigned link)
{ memset(p,0,48);wire_put64(p,11);wire_put32(p+8,100+link); }
/* Optional byte evidence comes from the real gateway payload builders and
 * shared C wire serializer; running the normal test never rewrites fixtures. */
static void vector(FILE *f,const char *name,uint8_t cmd,uint16_t seq,const uint8_t *data,uint16_t size,int last)
{
    uint8_t packet[300];size_t n=wire_frame(packet,cmd,seq,data,size);
    fprintf(f,"  \"%s\": \"",name);
    for(size_t i=0;i<n;i++)fprintf(f,"%02X",packet[i]);
    fprintf(f,"\"%s\n",last?"":",");
}
int main(int argc,char **argv)
{
    F4_Link_Init(); uint8_t p[48]={0};
    uint8_t info_vector[64],config_vector[280],valid_vector[96],stale_vector[96];
    request(0,0x40,1,p,0); assert(last_size==64 && wire_u16(last_data+30)==0x4d32);
    assert(wire_u16(last_data+26)==1 && !(wire_u32(last_data+36)&(1U<<7)));
    /* Pure servo/encoder firmware must not advertise retired IMU fusion. */
    assert(wire_u32(last_data+36)==0x3d && last_data[47]==0);
    request(1,0x40,1,p,0);memcpy(info_vector,last_data,sizeof(info_vector));
    assert(wire_u16(last_data+44)==30);
    uint8_t encoder_config[264];configuration(encoder_config);
    response(&links[1],0x42,2,100,0,encoder_config,264,0);
    memcpy(config_vector,last_data,sizeof(config_vector));
    assert(encoder_config[104+3*32+1]==2 && encoder_config[104+4*32+1]==2);
    assert(encoder_config[105]==1 && wire_u32(encoder_config+68)==1582 && wire_u32(encoder_config+72)==1582);
    /* Byte-level external STATE: source=5, servo-only status=3, valid pitch/yaw,
     * no IMU validity/timestamp, and the earliest real encoder timestamp. */
    f1_boot=22;f1_received=now;f1_offset=0;memset(f1_data,0,sizeof(f1_data));
    f1_data[13]=1;f1_data[14]=1;f1_data[15]=5;
    wire_put64(f1_data+24,now-500);wire_put64(f1_data+32,now-1000);
    wire_put32(f1_data+40,10000);wire_put32(f1_data+44,(uint32_t)-20000);
    make_snapshot(now);
    links[1].session=100;state_for(valid_vector,&links[1]);
    assert((wire_u32(snapshot+20)&0x78)==0x58 && wire_u64(snapshot+24)==0);
    assert(snapshot[91]==5 && snapshot[93]==3 && wire_u64(snapshot+60)==now-1000);
    assert((int32_t)wire_u32(snapshot+52)==10000 && (int32_t)wire_u32(snapshot+56)==-20000);
    /* Fresh publication cannot make stale encoder feedback valid. */
    make_snapshot(now+POSE_STALE_US+1);assert(!(wire_u32(snapshot+20)&0x18) && snapshot[91]==0);
    state_for(stale_vector,&links[1]);links[1].session=0;
    if(argc==2){
        FILE *f=fopen(argv[1],"wb");assert(f);fputs("{\n",f);
        vector(f,"GET_INFO_FPGA",0x80,1,info_vector,sizeof(info_vector),0);
        vector(f,"GET_CONFIG_FPGA",0x80,2,config_vector,sizeof(config_vector),0);
        vector(f,"STATE_ENCODER",0x81,(uint16_t)wire_u32(valid_vector+16),valid_vector,sizeof(valid_vector),0);
        vector(f,"STATE_STALE",0x81,(uint16_t)wire_u32(stale_vector+16),stale_vector,sizeof(stale_vector),1);
        fputs("}\n",f);assert(fclose(f)==0);
    }
    f1_boot=0;f1_received=0;memset(f1_data,0,sizeof(f1_data));
    for(unsigned i=0;i<2;i++) {
        memset(p,0,sizeof(p));wire_put32(p,100+i);wire_put64(p+4,11);
        request(i,0x41,2,p,16);assert(last_data[13]==0);
    }
    context(p,0);wire_put32(p+12,1);p[16]=1;wire_put32(p+20,1000000);wire_put16(p+40,10);
    request(0,0x46,3,p,48);assert(last_data[13]==1 && moves==1);
    request(0,0x46,3,p,48);assert(last_data[13]==1 && moves==1);
    wire_put32(p+20,2000000);request(0,0x46,3,p,48);assert(last_data[13]==8 && moves==1);
    context(p,1);wire_put32(p+12,2);p[16]=4;wire_put16(p+44,10);
    request(1,0x46,3,p,48);assert(last_data[13]==6 && moves==1);
    context(p,0);request(0,0x4c,4,p,12);assert(last_data[13]==0);
    uint64_t renewed=lease;now+=100;
    request(0,0x4c,4,p,12);assert(lease==renewed);
    context(p,0);wire_put32(p+12,2);p[16]=1;request(0,0x48,5,p,20);
    assert(last_data[13]==6 && !pending.active);
    context(p,1);wire_put32(p+12,7);wire_put64(p+16,99);
    request(1,0x45,4,p,24);assert(last_cmd==0x82 && last_size==40);
    uint64_t captured=wire_u64(last_data+24);now+=100;
    request(1,0x45,4,p,24);assert(last_cmd==0x82 && wire_u64(last_data+24)==captured);
    context(p,0);request(0,0x47,6,p,16);
    assert(last_data[13]==6 && !stops && !control_fault && axis_busy==1);
    assert(tasks[0].mask==1 && lease==renewed);
    context(p,1);request(1,0x47,5,p,16);assert(last_data[13]==6 && !stops);
    now+=2000000;F4_Link_Poll();assert(control_fault && stops);

    /* A rejected recovery command must preserve the fault it was meant to clear. */
    control_fault=0;fault=8;pending.active=0;f1_boot=0;
    context(p,0);wire_put32(p+12,2);p[16]=24;
    request(0,0x48,7,p,20);assert(last_data[13]==7 && fault==8);

    f1_boot=22;f1_received=now;memset(f1_data,0,sizeof(f1_data));
    /* The compatibility entry cannot bypass a latched fault. */
    uint8_t legacy[112]={0};wire_put64(legacy,11);wire_put32(legacy+8,100);
    wire_put32(legacy+12,2);memcpy(legacy+16,"ready",5);fault=9;
    request(0,0x50,8,legacy,21);assert(last_data[13]==9 && !pending.active);
    control_fault=0;fault=8;memcpy(legacy+16,"  measure   1   start",21);
    request(0,0x50,9,legacy,37);assert(last_data[13]==9);

    /* Admission happens before any selected F4 motor is armed. */
    control_fault=0;fault=0;axis_busy=0;
    for(unsigned i=0;i<5;i++)tasks[i].mask=24;
    context(p,0);wire_put32(p+12,2);p[16]=1;wire_put16(p+40,10);
    request(0,0x46,10,p,48);assert(last_data[13]==2 && moves==1);
    memset(tasks,0,sizeof(tasks));

    /* A local lease failure suspends proxy keepalive without a remote stop. */
    f1_data[12]=1;lease=now-1000000;F4_Link_Poll();assert(control_fault);
    unsigned count=internal_sends;uint32_t watchdogs=watchdog_count;
    now+=250000;F4_Link_Poll();
    assert(internal_sends==count && watchdog_count==watchdogs && !pending.active);

    /* A lease failure cancels calibration with a replayable final response. */
    control_fault=0;fault=0;pending.active=0;f1_data[12]=0;f1_data[14]=1;f1_received=now;
    context(p,0);request(0,0x4a,11,p,12);assert(zero_pending);
    context(p,0);request(0,0x47,12,p,16);assert(last_data[13]==6 && zero_pending);
    now+=1000001;f1_received=now;F4_Link_Poll();assert(!zero_pending && control_fault);
    context(p,0);request(0,0x4a,11,p,12);assert(last_data[13]==9);
    control_fault=0;fault=0;pending.active=0;f1_data[12]=0;f1_data[13]=1;
    f1_seq=UINT16_MAX;context(p,0);wire_put32(p+12,2);p[16]=25;wire_put16(p+40,10);
    request(0,0x46,13,p,48);assert(last_data[13]==9 && moves==1);

    /* The original per-axis stop remains available, including during a fault. */
    fault=8;axis_busy=1;tasks[0]=(Task){2,1,0,now};
    memset(legacy+16,0,sizeof(legacy)-16);wire_put32(legacy+12,3);memcpy(legacy+16,"stop 1",6);
    request(0,0x50,14,legacy,22);assert(last_data[13]==0 && !axis_busy && !tasks[0].mask);
    /* GET_RAW_IMU must not leak F1's servo sample counter into the old sensor
     * diagnostic, even if an old/nonzero internal payload remains buffered. */
    memset(f1_data+60,0x55,32);context(p,0);request(0,0x4d,15,p,12);
    assert(last_data[13]==0 && last_size==48);
    for(unsigned i=0;i<32;i++)if(i<12 || i>=16)assert(last_data[16+i]==0);
    assert(wire_u32(last_data+28)==config);
    puts("gateway: encoder capability/config/state, invalid IMU, sessions, retry and faults passed");
    return 0;
}
