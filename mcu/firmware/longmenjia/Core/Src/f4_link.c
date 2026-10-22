/* Five-axis gateway. PC owns motion; FPGA has an independent read-only session. */
#include "f4_link.h"
#include "internal.h"
#include "usart.h"
#include "../../../../config/pose_config.h"
#include <string.h>
#include <stdio.h>

/* F1 代理口：UART4 on PC10/PC11（USART1 PA9/PA10、USART2 PD6/PA3 的接收通路均实测不通） */
extern UART_HandleTypeDef huart4,huart6;
void MX_Extra_UART_Init(void);
typedef struct {
    uint16_t seq,n,response_size;
    uint8_t cmd, response_cmd, request[112], response[280];
    uint64_t tick;
} Transaction;
typedef struct {
    BoardPort port;
    uint32_t session,ack,sent_event,context_errors,event_overflow;
    uint16_t max_seq,rate;
    uint64_t last_state,last_event,last_query;
    Transaction cache[64]; uint8_t next;
} Link;
static Link links[2];
static BoardPort f1;
static uint64_t boot, f1_boot, f1_received, f1_state_received, f1_poll, lease, cycle;
/* 2026-10-22：F1 故障态(phase=5)去抖时间戳 */
static uint64_t f1_phase5_since;
static int64_t f1_offset;
static uint8_t f1_data[F1_STATE_BYTES], snapshot[96], control_fault, sticky_overflow;
/* 诊断：f1 端口累计收到的字节数（在 UART 接收中断里累加）。
 * 恒为 0 即表示该端口一字节都没收到，与帧解析无关。 */
static uint32_t f1_rx_bytes;
/* 诊断：f1_receive 实际被调用次数（= 完整解析出来的帧数） */
static uint32_t f1_frames;
/* 诊断：F1 回执帧(0xA0)累计数。F4 每 200ms 发一帧 INFO，F1 收到即回执，
 * 该计数增长即证明 F4→F1 方向通；恒为 0 说明 F4 的 TX 没到达 F1。 */
static uint32_t f1_replies;
/* 启动自测得到的 PORTC 引脚翻转掩码（在 extra_uart.c 中填写） */
extern uint32_t F4_PinMask;
static uint32_t links_pinmask_get(void) { return F4_PinMask; }
static uint16_t f1_seq, fault;
static uint32_t config=1, f1_config, sample, latest_motion, event_id, oldest_event=1, watchdog_count;
static uint8_t events[64][40];
static uint8_t zero_pending;
static Transaction zero_transaction;
static uint32_t zero_session;
static void response(Link *,uint8_t,uint16_t,uint32_t,uint8_t,const uint8_t *,uint16_t,Transaction *);
static void finish_zero(uint8_t result, const uint8_t *data, uint16_t n)
{
    if (!zero_pending) return;
    zero_pending=0;
    Transaction *c=&links[0].cache[links[0].next++%64];
    *c=zero_transaction; c->tick=board_us();
    response(&links[0],0x4a,c->seq,zero_session,result,data,n,c);
}
static void abort_zero(void)
{
    finish_zero(9,0,0);
}
typedef struct { uint32_t id; uint8_t mask, home; uint64_t start; } Task;
static Task tasks[5];
static struct { uint8_t cmd,n,retries,active,result; uint16_t seq; uint8_t data[16]; uint64_t sent; } pending;

void F4_ConfigChanged(void) { if (config!=UINT32_MAX) ++config; else fault=10; }
void F4_LegacyNotice(const char *text)
{
    if (!links[0].session) return;
    uint8_t data[140]; wire_put64(data,boot); wire_put32(data+8,links[0].session);
    size_t n=strlen(text); if (n>128) n=128; memcpy(data+12,text,n);
    board_port_send(&links[0].port,0x91,(uint16_t)latest_motion,data,(uint16_t)(12+n),0);
}
static int f1_online(uint64_t now) { return f1_boot && now-f1_received<50000; }
static uint8_t busy_mask(void)
{
    int32_t position[3]; uint32_t limit[3]; uint8_t busy,valid;
    F4_AxesSnapshot(position,limit,&busy,&valid);
    for (unsigned i=0;i<5;i++) busy|=tasks[i].mask;
    if (f1_data[12]>=1 && f1_data[12]<=3) busy|=24;
    if (zero_pending) busy|=24;
    return busy;
}
static void internal_send(uint8_t cmd, const uint8_t *angles, uint8_t n)
{
    memset(&pending,0,sizeof(pending)); pending.cmd=cmd; pending.n=(uint8_t)(8+n);
    wire_put64(pending.data,f1_boot); if (n) memcpy(pending.data+8,angles,n);
    /* Exhaustion fails closed; reboot is required instead of reusing IDs. */
    if (f1_seq==UINT16_MAX) { fault=8; return; }
    pending.seq=++f1_seq; pending.active=1; pending.sent=board_us();
    board_port_send(&f1,cmd,pending.seq,pending.data,pending.n,0);
}
static void link_fault(void)
{
    abort_zero();
    F4_AxesStop(); control_fault=1;
    /* Cancel queued requests and suspend keepalive. F1 handles its own local
     * link timeout; no remote all-axis stopping instruction is transmitted. */
    f1.control_count=0; f1.control_head=f1.control_tail=0;
    pending.active=0;
}
static void event(uint32_t id, uint8_t mask, uint16_t type, uint16_t result)
{
    if (event_id==UINT32_MAX) { fault=9; link_fault(); return; }
    uint32_t min_ack=event_id;
    for (unsigned i=0;i<2;i++) if (links[i].session && links[i].ack<min_ack) min_ack=links[i].ack;
    if (event_id-oldest_event+1>=64) {
        if (oldest_event>min_ack) {
            for (unsigned i=0;i<2;i++)
                if (links[i].session && oldest_event>links[i].ack) wire_count(&links[i].event_overflow);
            sticky_overflow=1; fault=9; link_fault();
        }
        ++oldest_event;
    }
    uint8_t *p=events[(++event_id-1)%64]; memset(p,0,40);
    wire_put64(p,boot); wire_put32(p+12,event_id); wire_put64(p+16,board_us());
    wire_put32(p+24,id); wire_put16(p+28,type); wire_put16(p+30,result);
    wire_put32(p+32,config); wire_put16(p+36,fault); p[38]=mask;
    p[39]=fault ? 5 : busy_mask() ? 1 : 0;
}
static void cancel_tasks(uint16_t type, uint16_t result)
{
    for (unsigned i=0;i<5;i++) if (tasks[i].mask) {
        uint32_t id=tasks[i].id; uint8_t mask=tasks[i].mask; tasks[i].mask=0;
        event(id,mask,type,result);
    }
}
static uint64_t mapped(uint64_t tick)
{
    int64_t value=(int64_t)tick+f1_offset;
    return tick && value>0 ? (uint64_t)value : 0;
}
static void f1_receive(void *ctx, uint8_t cmd, uint16_t seq, const uint8_t *p, uint16_t n, uint64_t tick)
{
    (void)ctx;
    ++f1_frames;
    if (cmd==F1_REPLY) ++f1_replies;
    if (!((cmd==F1_STATE && n==F1_STATE_BYTES) || (cmd==F1_REPLY && n==12))) return;
    uint64_t identity=wire_u64(p);
    if (!identity) return;
    if (f1_boot && identity!=f1_boot) {
        fault=8; F4_AxesStop(); cancel_tasks(5,1); memset(f1_data,0,sizeof(f1_data));
        f1_config=0; f1_offset=0; abort_zero();
        pending.active=0; f1_seq=0;
    }
    f1_boot=identity; f1_received=tick;
    if (cmd==F1_STATE) {
        f1_state_received=tick;
        /* Polling map uses end-of-receive minus maximum source timestamp and
         * serialization. It is approximate and flagged in every external STATE. */
        uint64_t source=wire_u64(p+16);
        for (unsigned i=0;i<2;i++) if (wire_u64(p+24+8*i)>source) source=wire_u64(p+24+8*i);
        if (source) {
            uint64_t publish=(source&~UINT64_C(0xffffffff))|wire_u32(p+124);
            if (publish<source) publish+=UINT64_C(0x100000000);
            int64_t candidate=(int64_t)tick-2995-(int64_t)publish;
            /* 2026-10-22：原先取历史最小值（candidate<f1_offset），一旦某个异常样本把
             * 偏移拉偏就永远不会回调，导致 mapped() 恒偏出 POSE_STALE_US 之外，
             * 所有 GO 任务都会在 100 ms 后被误判 fault=5(DRIVER)。
             * 改为带 ±50 ms 容带的跟踪：首帧直接采用，之后只接受合理范围内的新值。 */
            if (!wire_u64(f1_data) || f1_offset==0) f1_offset=candidate;
            else if (candidate>=f1_offset-50000 && candidate<=f1_offset+50000) f1_offset=candidate;
        }
        memcpy(f1_data,p,n);
        uint32_t c=wire_u32(p+120);
        if (f1_config && c!=f1_config) F4_ConfigChanged();
        f1_config=c;
    } else if (pending.active && seq==pending.seq && p[8]==pending.cmd) {
        pending.active=0; pending.result=p[9];
        if (pending.result!=0 && pending.result!=1) {
            fault=5;
            link_fault();
            cancel_tasks(5,1);
        }
    }
}
static int f1_feedback_fresh(uint64_t now)
{
    if (!f1_online(now)) return 0;
    for (unsigned i=0;i<2;i++) {
        uint64_t t=mapped(wire_u64(f1_data+24+8*i));
        if (!t || t>now || now-t>POSE_STALE_US) return 0;
    }
    return 1;
}
static void make_snapshot(uint64_t now)
{
    memset(snapshot,0,sizeof(snapshot));
    int32_t positions[3]; uint32_t limits[3]; uint8_t busy,valid;
    F4_AxesSnapshot(positions,limits,&busy,&valid);
    wire_put64(snapshot,boot); wire_put32(snapshot+12,config); wire_put32(snapshot+16,++sample);
    uint32_t flags=valid | (1U<<11);
    if (POSE_CONFIG_VERIFIED) flags|=1U<<7;
    wire_put64(snapshot+32,now);
    for (unsigned i=0;i<3;i++) if (valid&(1U<<i)) {
        wire_put32(snapshot+40+4*i,(uint32_t)positions[i]); snapshot[90]|=(uint8_t)(1U<<(2*i));
    }
    snapshot[89]=valid;
    if (f1_online(now)) {
        snapshot[89]|=f1_data[14] ? 0x18 : 0;
        if (f1_data[13]) flags|=1U<<6;
        uint64_t imu=mapped(wire_u64(f1_data+16));
        if (imu && imu<=now && now-imu<=POSE_STALE_US) { wire_put64(snapshot+24,imu); flags|=1U<<5; }
        uint64_t earliest=0;
        for (unsigned i=0;i<2;i++) {
            uint64_t servo=mapped(wire_u64(f1_data+24+8*i));
            uint8_t source=(uint8_t)((f1_data[15]>>(2*i))&3);
            if (!servo || servo>now || now-servo>POSE_STALE_US || !source || !f1_data[13]) continue;
            flags|=1U<<(3+i); wire_put32(snapshot+52+4*i,wire_u32(f1_data+40+4*i));
            snapshot[91]|=(uint8_t)(source<<(2*i));
            if (!earliest || servo<earliest) earliest=servo;
        }
        wire_put64(snapshot+60,earliest);
        snapshot[93]=!f1_data[13] ? 1 : snapshot[91]==10 ? 2 : snapshot[91] ? 3 : 0;
        if (f1_data[12]==2 || f1_data[12]==3) snapshot[92]=f1_data[12];
    }
    if (busy_mask()) { flags|=1U<<8; if (!snapshot[92]) snapshot[92]=1; }
    if (fault) snapshot[92]=5;
    if (links[0].port.replaced || links[1].port.replaced) flags|=1U<<9;
    if (sticky_overflow) flags|=1U<<10;
    wire_put32(snapshot+20,flags); wire_put32(snapshot+80,latest_motion); wire_put32(snapshot+84,event_id);
    snapshot[88]=0x1f; wire_put16(snapshot+94,fault);
}
static void state_for(uint8_t *out, Link *l)
{
    memcpy(out,snapshot,96); wire_put32(out+8,l->session);
    uint32_t flags=wire_u32(out+20)&~((1U<<9)|(1U<<10));
    if (l->port.replaced) flags|=1U<<9;
    if (l->event_overflow) flags|=1U<<10;
    wire_put32(out+20,flags);
}
static void configuration(uint8_t *p)
{
    memset(p,0,264); wire_put32(p,config); wire_put16(p+4,1000); wire_put16(p+6,200);
    p[8]=3; p[11]=1; p[12]=31; wire_put16(p+14,(uint16_t)(POSE_WAIT_US/1000));
    const float rotation[4]={POSE_Q_BI_W,POSE_Q_BI_X,POSE_Q_BI_Y,POSE_Q_BI_Z};
    for (unsigned i=0;i<4;i++) wire_put32(p+16+4*i,(uint32_t)(int32_t)(rotation[i]*1073741824.0f));
    memcpy(p+32,f1_data+108,12); wire_put32(p+56,1); memcpy(p+60,f1_data+100,8);
    wire_put32(p+68,792); wire_put32(p+72,792); wire_put32(p+76,(uint32_t)(POSE_STABLE_RATE_DPS*1000));
    wire_put32(p+80,POSE_STALE_US); wire_put32(p+84,85000); wire_put32(p+88,POSE_DISAGREEMENT_MDEG);
    wire_put32(p+92,180000); wire_put32(p+96,1); wire_put16(p+100,POSE_SERVO_WEIGHT); wire_put16(p+102,POSE_IMU_WEIGHT);
    int32_t position[3]; uint32_t limits[3]; uint8_t busy,valid;
    F4_AxesSnapshot(position,limits,&busy,&valid);
    for (unsigned j=0;j<5;j++) {
        uint8_t *a=p+104+32*j; int rotation=j>=3;
        a[0]=rotation?2:1; a[1]=rotation?4:1; a[2]=rotation?2:1; a[3]=rotation?7:10;
        wire_put32(a+4,rotation?(uint32_t)-60000:0); wire_put32(a+8,rotation?60000:100000000);
        wire_put32(a+12,rotation?2000:60); wire_put32(a+20,rotation?270000:100000000);
        wire_put32(a+24,rotation?4095:limits[j]); a[28]=(uint8_t)(!rotation && j!=0); a[29]=(uint8_t)rotation;
    }
}
static void response(Link *l, uint8_t cmd, uint16_t seq, uint32_t session, uint8_t result, const uint8_t *data, uint16_t n, Transaction *cache)
{
    uint8_t out[280]={0}; wire_put64(out,boot); wire_put32(out+8,session); out[12]=cmd; out[13]=result;
    if (n) memcpy(out+16,data,n);
    if (cache) { memcpy(cache->response,out,16+n); cache->response_size=(uint16_t)(16+n); cache->response_cmd=0x80; }
    if (!board_port_send(&l->port,0x80,seq,out,(uint16_t)(16+n),0)) { fault=8; link_fault(); }
}
static uint16_t expected_size(uint8_t cmd)
{
    static const uint8_t lengths[]={0,16,12,16,12,24,48,16,20,16,12,12,12,12};
    if (cmd==0x47) return UINT16_MAX; /* Retired, never reuse its opcode. */
    if (cmd>=0x40 && cmd<=0x4d) return lengths[cmd-0x40];
    if (cmd==0x51) return 16;
    if (cmd==0x52) return 12;
    return UINT16_MAX;
}

static void receive(void *ctx, uint8_t cmd, uint16_t seq, const uint8_t *p, uint16_t n, uint64_t tick)
{
    Link *l=ctx; unsigned index=(unsigned)(l-links); uint8_t out[264]={0}; uint16_t out_n=0;
    uint8_t result=0; uint32_t session=n>=12 ? wire_u32(p+8) : 0;
    if (cmd==0x40) {
        if (n) { response(l,cmd,seq,0,3,0,0,0); return; }
        wire_put64(out,board_device_id()); wire_put16(out+8,2); wire_put16(out+10,1); wire_put16(out+14,0x4d32);
        wire_put32(out+16,1000000); wire_put32(out+20,boot?0x3f:0x1f); wire_put16(out+24,1024);
        wire_put16(out+26,200); wire_put16(out+28,index?30:150); out[30]=31; out[31]=1;
        wire_put32(out+32,config); wire_put16(out+36,links[1].session?links[1].rate:0);
        wire_put16(out+38,links[0].session?links[0].rate:0);
        if (event_id>l->ack) { wire_put32(out+40,l->ack+1<oldest_event?oldest_event:l->ack+1); wire_put32(out+44,event_id); }
        response(l,cmd,seq,0,boot?0:9,out,48,0); return;
    }
    if (cmd==0x41) {
        if (n!=16 || wire_u32(p+12)) { response(l,cmd,seq,0,3,0,0,0); return; }
        session=wire_u32(p);
        if (!session || wire_u64(p+4)!=boot || !boot) { response(l,cmd,seq,session,5,0,0,0); return; }
        if (session!=l->session) {
            /* 2026-10-22：新会话接管旧任务属于正常接管，不是链路故障。
             * 原来这里 fault=8 + link_fault()，导致"每次重开工具都报 LEASE_LOST、
             * 所有命令返回 9"，而租约其实一直健康（实测最大 392 ms << 1 s）。
             * 现在只静默取消旧任务（result=2 表示被新会话取代）。 */
            if (index==0 && busy_mask()) cancel_tasks(5,2);
            l->session=session; l->max_seq=0; l->last_query=0; memset(l->cache,0,sizeof(l->cache));
            l->ack=oldest_event-1; l->sent_event=l->ack;
        }
        if (index==0) lease=tick;
        wire_put32(out,config); wire_put32(out+4,latest_motion);
        response(l,cmd,seq,session,0,out,8,0); return;
    }
    if (n<12) { response(l,cmd,seq,0,3,0,0,0); return; }
    if (!boot || wire_u64(p)!=boot || session!=l->session || !session) {
        wire_count(&l->context_errors); response(l,cmd,seq,session,5,0,0,0); return;
    }
    for (unsigned i=0;i<64;i++) if (l->cache[i].seq==seq && seq) {
        Transaction *c=&l->cache[i];
        if (c->cmd==cmd && c->n==n && n<=112 && !memcmp(c->request,p,n))
            board_port_send(&l->port,c->response_cmd,seq,c->response,c->response_size,0);
        else response(l,cmd,seq,session,8,0,0,0);
        return;
    }
    if (!index && zero_pending && zero_transaction.seq==seq) {
        if (zero_transaction.cmd!=cmd || zero_transaction.n!=n || memcmp(zero_transaction.request,p,n))
            response(l,cmd,seq,session,8,0,0,0);
        return;
    }
    if (!seq || seq<=l->max_seq) { response(l,cmd,seq,session,10,0,0,0); return; }
    if (!index && (cmd==0x42 || cmd==0x44 || cmd==0x4b || cmd==0x4d || cmd==0x52)) {
        if (l->last_query && tick-l->last_query<100000) { response(l,cmd,seq,session,2,0,0,0); return; }
        l->last_query=tick;
    }
    uint16_t expected=expected_size(cmd);
    if ((cmd!=0x50 && n!=expected) || (cmd==0x50 && (n<17 || n>111))) {
        response(l,cmd,seq,session,expected==UINT16_MAX && cmd!=0x50 ? 6 : 3,0,0,0); return;
    }
    unsigned slot=l->next%64;
    if (l->cache[slot].seq && tick-l->cache[slot].tick<2000000ULL) {
        response(l,cmd,seq,session,2,0,0,0); return;
    }
    Transaction *c=&l->cache[l->next++%64]; memset(c,0,sizeof(*c));
    c->seq=seq; c->cmd=cmd; c->n=n; c->tick=tick; memcpy(c->request,p,n); l->max_seq=seq;
    if (index && (cmd==0x46 || cmd==0x48 || cmd==0x4a || cmd==0x4c || cmd==0x4d || cmd>=0x50)) result=6;
    else switch (cmd) {
    case 0x42: configuration(out); out_n=264; break;
    case 0x43: {
        uint16_t rate=wire_u16(p+12);
        if (wire_u16(p+14) || !(rate==0 || (index ? rate==100 || rate==200 : rate==10 || rate==20))) result=4;
        else { l->rate=rate; wire_put16(out,rate); out_n=4; }
        break;
    }
    case 0x44: state_for(out,l); out_n=96; break;
    case 0x45:
        if (!index) result=6;
        else {
            uint8_t sync[40]; wire_put64(sync,boot); wire_put32(sync+8,session);
            memcpy(sync+12,p+12,12); wire_put64(sync+24,tick); wire_put64(sync+32,board_us());
            board_port_send(&l->port,0x82,seq,sync,40,0);
            /* Retries preserve the captured timestamps. */
            memcpy(c->response,sync,40); c->response_size=40; c->response_cmd=0x82; return;
        }
        break;
    case 0x46: case 0x48: {
        uint32_t id=wire_u32(p+12); uint8_t mask=p[16];
        if (!id || id<=latest_motion) { result=10; break; }
        if (!mask || (mask&~31) || p[17] || wire_u16(p+18)) { result=4; break; }
        if (cmd==0x48 && mask!=24) { result=6; break; }
        if (sticky_overflow || fault==9 || fault==10 || (fault && cmd!=0x48)) { result=9; break; }
        if (busy_mask()&mask) { result=2; break; }
        if ((mask&24) && (!f1_online(tick) || pending.active)) { result=7; break; }
        if ((mask&24) && f1_seq==UINT16_MAX) { result=9; break; }
        if (cmd==0x46 && (mask&24) && (!f1_data[13] || (mask&24)!=24)) { result=7; break; }
        unsigned slot=0; while (slot<5 && tasks[slot].mask) ++slot;
        if (slot==5) { result=2; break; }
        int32_t targets[5]={0}; uint16_t rpm[3]={0};
        if (cmd==0x46) {
            if (wire_u16(p+46)) { result=4; break; }
            for (unsigned i=0;i<5;i++) {
                targets[i]=(int32_t)wire_u32(p+20+4*i);
                if (!(mask&(1U<<i)) && targets[i]) result=4;
                if ((mask&(1U<<i)) && (targets[i]<(i<3?0:-60000) || targets[i]>(i<3?100000000:60000))) result=4;
            }
            for (unsigned i=0;i<3;i++) {
                rpm[i]=wire_u16(p+40+2*i);
                if ((mask&(1U<<i)) ? (!rpm[i] || rpm[i]>60) : rpm[i]!=0) result=4;
            }
            if (result) break;
            if (mask&7) { result=F4_AxesMove(mask&7,targets,rpm); if (result!=1) break; }
        }
        if (cmd==0x48) { fault=0; control_fault=0; }
        tasks[slot]=(Task){id,mask,(uint8_t)(cmd==0x48),tick}; latest_motion=id;
        if (mask&24) {
            uint8_t angles[8]; wire_put32(angles,(uint32_t)targets[3]); wire_put32(angles+4,(uint32_t)targets[4]);
            internal_send(cmd==0x48 ? F1_READY : F1_GO,angles,cmd==0x48?0:8);
        }
        result=1; wire_put32(out,id); out_n=4; event(id,mask,1,0); break;
    }
    case 0x49: {
        uint32_t ack=wire_u32(p+12);
        if (ack<l->ack || ack>l->sent_event) result=4;
        else { l->ack=ack; wire_put32(out,ack); out_n=4; }
        break;
    }
    case 0x4a:
        if (f1_seq==UINT16_MAX || sticky_overflow || fault) result=9;
        else if (busy_mask() || zero_pending || !f1_online(tick) || pending.active || !f1_data[14]) result=7;
        else {
            internal_send(F1_ZERO,0,0); zero_pending=1; result=1;
            zero_transaction=*c; zero_session=session; lease=tick;
            memset(c,0,sizeof(*c));
            return; /* HEARTBEAT continues while the calibration transaction waits. */
        }
        break;
    case 0x4b:
        wire_put32(out,l->port.parser.crc_errors); wire_put32(out+4,l->port.parser.length_errors);
        wire_put32(out+8,l->port.parser.timeouts); wire_put32(out+12,l->context_errors);
        /* 2026-10-22 诊断：区分"字节没到""到了拼不成帧""拼成了但判定不认"。
         *   +16 f1 口累计字节   +20 f1 完整帧数   +24 启动时 PORTC 翻转掩码 */
        wire_put32(out+16,f1.rx_total);
        wire_put32(out+20,f1_frames);
        wire_put32(out+24,f1_replies);
        wire_put32(out+28,l->port.replaced);
        wire_put32(out+32,l->event_overflow); wire_put32(out+36,watchdog_count);
        /* 2026-10-22：40..63 直接暴露 UART4/GPIO 寄存器，用来判断"引脚有信号但收不到"
         * 究竟是外设没开接收、引脚没进复用模式，还是复用号不对。 */
        wire_put32(out+40,(uint32_t)UART4->CR1);
        wire_put32(out+44,(uint32_t)UART4->SR);
        wire_put32(out+48,f1_data[91]);   /* F1 侧累计收到的 INFO 帧数（低 8 位） */
        wire_put32(out+52,f1_data[92]);   /* F1 侧 USART1 累计收到字节（低8位） */
        wire_put32(out+56,f1_data[93]);   /* F1 侧接收失败/重启次数 */
        wire_put32(out+60,f1_data[94]);   /* F1 侧解析 CRC 错 */
        wire_put32(out+64,f1_data[95]);   /* F1 侧解析超时 */
        wire_put32(out+68,f1_data[96]);   /* F1 侧 USART1 RxState */
        wire_put32(out+72,f1_data[97]);   /* F1 侧 USART1 CR1 低 8 位 */
        wire_put32(out+76,f1_data[98]);   /* F1 侧 port.failed */
        wire_put32(out+80,f1_data[99]);   /* F1 侧 USART1 ErrorCode */
        /* 2026-10-22：租约与任务诊断。看门狗只在 now-lease>=1s 且忙时触发，
         * 但实测心跳每 300~400 ms 都有 result=0 回应却仍报 LEASE_LOST，
         * 这里直接把租约年龄和忙掩码暴露出来定位。 */
        wire_put32(out+100,(uint32_t)(board_us()-lease));
        wire_put32(out+104,busy_mask());
        wire_put32(out+108,pending.active ? (uint32_t)(board_us()-pending.sent) : 0xFFFFFFFFU);
        /* F1 侧舵机总线就绪失败步号 / 驱动状态（108/109 字节） */
        wire_put32(out+112,f1_data[108]);
        wire_put32(out+116,f1_data[109]);
        {
            /* 2026-10-22：直接暴露 f1_feedback_fresh() 的判据，定位 fault=5 的真实原因：
             *   +84/+88 两个舵机时间戳映射后的"年龄"（0xFFFFFFFF 表示映射失败/为 0）
             *   +92 f1_offset 低 32 位   +96 phase | zero_valid<<8 | home<<16 | servo_valid<<24 */
            uint64_t nowf=board_us();
            for (unsigned i=0;i<2;i++) {
                uint64_t t=mapped(wire_u64(f1_data+24+8*i));
                uint32_t age=0xFFFFFFFFU;
                if (t) { int64_t d=(int64_t)nowf-(int64_t)t; age=(d<0)?0xFFFFFFFEU:(uint32_t)d; }
                wire_put32(out+84+4*i,age);
            }
            wire_put32(out+92,(uint32_t)(int32_t)f1_offset);
            wire_put32(out+96,(uint32_t)f1_data[12] | ((uint32_t)f1_data[13]<<8)
                              | ((uint32_t)f1_data[14]<<16) | ((uint32_t)(f1_data[15]&0xF)<<24));
        }
        out_n=120; break;
    case 0x4c: break;
    case 0x4d:
        memcpy(out,f1_data+60,32); wire_put64(out,mapped(wire_u64(out))); wire_put32(out+12,config);
        if (!f1_online(tick) || !wire_u64(out) || tick-wire_u64(out)>POSE_STALE_US) out[30]=0;
        out_n=32; break;
    case 0x51:
        if (p[13] || p[14] || p[15]) result=4;
        else result=F4_ManualZero(p[12]);
        if (!result) { F4_ConfigChanged(); wire_put32(out,config); out_n=4; }
        break;
    case 0x52:
        if (!f1_online(tick)) result=7;
        else {
            memcpy(out,f1_data+56,4);
            for (unsigned i=0;i<2;i++) {
                uint16_t raw=wire_u16(out+2*i);
                wire_put32(out+4+4*i,((uint32_t)raw*270000U+2047U)/4095U);
            }
            memcpy(out+12,f1_data+48,8); memcpy(out+20,f1_data+40,8);
            out[28]=f1_data[15]; out[29]=f1_data[13]; out_n=32;
        }
        break;
    case 0x50: {
        /* Existing textual functions are contained within authenticated framing. */
        uint32_t id=wire_u32(p+12);
        if (id<=latest_motion || !id) { result=10; break; }
        char line[96]; unsigned size=n-16;
        for (unsigned i=0;i<size;i++) if (p[16+i]<32 || p[16+i]>126) result=4;
        if (result) break;
        memcpy(line,p+16,size); line[size]=0;
        char *first=line; while (*first==' ') ++first;
        if (first!=line) memmove(line,first,strlen(first)+1);
        size_t trimmed=strlen(line); while (trimmed && line[trimmed-1]==' ') line[--trimmed]=0;
        if (!strcmp(line,"ready") || !strcmp(line,"gimbal ready")) {
            if (sticky_overflow || fault==9 || fault==10 || f1_seq==UINT16_MAX) { result=9; break; }
            if (!f1_online(tick) || pending.active || (busy_mask()&24)) { result=7; break; }
            unsigned slot=0; while (slot<5 && tasks[slot].mask) ++slot;
            if (slot==5) { result=2; break; }
            fault=0; control_fault=0; tasks[slot]=(Task){id,24,1,tick}; latest_motion=id; internal_send(F1_READY,0,0);
            result=1; wire_put32(out,id); out_n=4; event(id,24,1,0); break;
        }
        if (!strcmp(line,"get") || !strcmp(line,"gimbal get")) {
            if (!f1_online(tick)) result=7;
            else {
                int bytes=snprintf((char *)out,sizeof(out),"raw %u %u absolute_mdeg %lu %lu relative_mdeg %ld %ld fused_mdeg %ld %ld source %u\r\n",
                    wire_u16(f1_data+56),wire_u16(f1_data+58),
                    (unsigned long)((uint32_t)wire_u16(f1_data+56)*270000U/4095U),
                    (unsigned long)((uint32_t)wire_u16(f1_data+58)*270000U/4095U),
                    (long)(int32_t)wire_u32(f1_data+48),(long)(int32_t)wire_u32(f1_data+52),
                    (long)(int32_t)wire_u32(f1_data+40),(long)(int32_t)wire_u32(f1_data+44),f1_data[15]);
                out_n=(uint16_t)bytes;
            }
            break;
        }
        if (!strncmp(line,"gimbal go ",10)) {
            if (sticky_overflow || fault || f1_seq==UINT16_MAX) { result=9; break; }
            long pitch,yaw; char extra;
            if (sscanf(line+10,"%ld %ld %c",&pitch,&yaw,&extra)!=2 || pitch < -60000 || pitch > 60000 || yaw < -60000 || yaw > 60000) { result=4; break; }
            if (!f1_online(tick) || pending.active || !f1_data[13] || (busy_mask()&24)) { result=7; break; }
            unsigned slot=0; while (slot<5 && tasks[slot].mask) ++slot;
            if (slot==5) { result=2; break; }
            uint8_t angles[8]; wire_put32(angles,(uint32_t)pitch); wire_put32(angles+4,(uint32_t)yaw);
            tasks[slot]=(Task){id,24,0,tick}; latest_motion=id; internal_send(F1_GO,angles,8);
            result=1; wire_put32(out,id); out_n=4; event(id,24,1,0); break;
        }
        uint8_t legacy_motion=0,legacy_stop=0;
        char verb[16]={0},axis[4]={0},option[8]={0};
        (void)sscanf(line,"%15s %3s %7s",verb,axis,option);
        if (!strcmp(verb,"go")) legacy_motion=3;
        else if (!strcmp(verb,"out")) legacy_motion=4;
        else if (!strcmp(verb,"measure") && !strcmp(option,"start") &&
            axis[0]>='1' && axis[0]<='3' && !axis[1]) legacy_motion=(uint8_t)(1U<<(axis[0]-'1'));
        /* 2026-10-22：wake 的语义是"停止全部"，原来只清轴任务(7)，
         * 云台任务(bit3/bit4 = 24)会残留；下一个会话的 OPEN 检测到忙碌后会
         * 取消它并锁存 fault=8(LEASE_LOST)，表现为"每次重开工具就报链路丢失"。
         * 这里改为清除全部五个任务槽。 */
        else if (!strcmp(verb,"wake")) legacy_stop=31;
        else if (!strcmp(verb,"stop") && axis[0]>='1' && axis[0]<='3' && !axis[1])
            legacy_stop=(uint8_t)(1U<<(axis[0]-'1'));
        /* Queries and the driver's existing stop commands remain usable in a
         * fault; ordinary legacy motion cannot bypass the gateway interlock. */
        if (!legacy_stop && strcmp(verb,"state") &&
            (sticky_overflow || (fault && legacy_motion))) { result=9; break; }
        if (legacy_motion) {
            if (busy_mask()&legacy_motion) { result=2; break; }
            unsigned slot=0; while (slot<5 && tasks[slot].mask) ++slot;
            if (slot==5) { result=2; break; }
        }
        F4_Legacy(line,(char *)out,sizeof(out)); out_n=(uint16_t)strlen((char *)out);
        result=strstr((char *)out,"error") ? 4 : 0;
        if (result) F4_LegacyNotice((char *)out);
        if (!result) {
            latest_motion=id;
            if (legacy_stop) for (unsigned i=0;i<5;i++) if (tasks[i].mask&legacy_stop) {
                uint32_t old=tasks[i].id; uint8_t mask=tasks[i].mask; tasks[i].mask=0; event(old,mask,5,2);
            }
            if (legacy_motion) {
                unsigned slot=0; while (slot<5 && tasks[slot].mask) ++slot;
                if (slot<5) {
                    tasks[slot]=(Task){id,legacy_motion,0,tick}; event(id,legacy_motion,1,0);
                } else { result=9; link_fault(); }
            }
        }
        break;
    }
    default: result=6;
    }
    if (index==0 && (result==0 || result==1)) lease=tick;
    if (result!=0 && result!=1) out_n=0;
    response(l,cmd,seq,session,result,out,out_n,c);
}

void F4_Link_Init(void)
{
    boot=board_boot_id(); MX_Extra_UART_Init();
    links[0].rate=10; links[1].rate=200;
    board_port_init(&links[0].port,&huart3,receive,&links[0],150);
    links[0].port.tx_bytes_per_second=5760;
    /* 2026-10-21：F1 代理口固定为 UART4 (PC10/PC11)。
     * 这是今晚唯一用真实 F1 帧验证通过的配置（8/8 result=0，raw 1866/2415）。
     * 曾试过 USART2(PD6/PA3) 与 USART6(PC6/PC7)，均无法接收；
     * FPGA 只读口保留在 USART6，后续接 FPGA 时用回。 */
    board_port_init(&links[1].port,&huart6,receive,&links[1],30);
    /* F1 代理口用循环 DMA 接收：460800 / 约 2.76 万字节每秒，逐字节中断撑不住，
     * 会因 ORE 溢出后 RXNEIE 被关闭而永久收不到数据（2026-10-22 实测：
     * CR1=0x200C 说明 RXNEIE=0，SR=0xF8 说明 RXNE 与 ORE 同时挂起）。 */
    board_port_init_dma(&f1,&huart4,f1_receive,0,30);
    make_snapshot(board_us());
}
void F4_Link_Rx(UART_HandleTypeDef *u) { if (u==&huart4) ++f1_rx_bytes; for(unsigned i=0;i<2;i++) board_port_rx(&links[i].port,u); board_port_rx(&f1,u); }
void F4_Link_Error(UART_HandleTypeDef *u) { for(unsigned i=0;i<2;i++) board_port_error(&links[i].port,u); board_port_error(&f1,u); }
void F4_Link_TxDone(UART_HandleTypeDef *u) { for(unsigned i=0;i<2;i++) board_port_tx_done(&links[i].port,u); board_port_tx_done(&f1,u); }
void F4_Link_Poll(void)
{
    /* 2026-10-22：删除"上位机口 failed 即判链路丢失"的判据。
     * 该判据把一次瞬时接收错误（ORE）当成上位机失联，立刻 fault=8 并取消全部运动；
     * 而该错误会被 board_port_poll 的自愈在一个轮询内清掉，故障却已锁存。
     * 真正的失联由下方 1 秒租约看门狗负责（本轮询里的 lease 检查），语义更准确。 */
    for (unsigned i=0;i<2;i++) board_port_poll(&links[i].port);
    board_port_poll(&f1);
    uint64_t now=board_us();
    /* 2026-10-22：INFO 是存活心跳，不能因为 control_fault 就停发。
     * 原来故障后停发 INFO，F1 侧 last_contact 超时即进入不可恢复的故障态，
     * 而 F1 的恢复又要求"最近收到过 INFO"，形成互相等待的死锁（实测 phase=5 卡死）。 */
    if (now-f1_poll>=200000) { f1_poll=now; board_port_send(&f1,F1_INFO,0,0,0,0); }
    if (pending.active && now-pending.sent>=200000) {
        if (pending.retries<2) {
            ++pending.retries; pending.sent=now;
            board_port_send(&f1,pending.cmd,pending.seq,pending.data,pending.n,0);
        } else { fault=8; link_fault(); cancel_tasks(5,1); }
    }
    if (!control_fault && (busy_mask() || zero_pending) && now-lease>=1000000) {
        wire_count(&watchdog_count); fault=8; link_fault(); cancel_tasks(8,3);
    }
    int32_t position[3]; uint32_t limits[3]; uint8_t busy,valid;
    F4_AxesSnapshot(position,limits,&busy,&valid);
    /* 没有云台任务时清掉故障态去抖时间戳，保证每个新任务重新计时 */
    if (!(busy_mask()&24)) f1_phase5_since=0;
    for (unsigned i=0;i<5;i++) if (tasks[i].mask) {
        Task *t=&tasks[i];
        if ((t->mask&7) && F4_AxesResult(t->mask&7)==9) {
            fault=5; link_fault(); cancel_tasks(5,1); break;
        }
        if ((t->mask&24) && f1_data[12]==5) {
            /* 2026-10-22：对 F1 的故障态去抖。F1 在回正/校准过程中可能出现短暂的
             * phase=5，它自己的自愈逻辑会在约 1 秒内恢复；原来的立即取消相当于把
             * 瞬时抖动当成永久驱动故障，导致 /home 和 /gimbalgo 一进入就被取消。
             * 只有持续超过 1.5 秒才判故障。 */
            if (!f1_phase5_since) f1_phase5_since=now;
            else if (now-f1_phase5_since>3000000ULL) {
                fault=5; link_fault(); cancel_tasks(5,1); break;
            }
        } else if (f1_data[12]!=5) {
            f1_phase5_since=0;
        }
        if ((t->mask&24) && !t->home && !pending.active && now-t->start>100000 && !f1_feedback_fresh(now)) {
            fault=5; link_fault(); cancel_tasks(5,1); break;
        }
        if (now-t->start>(t->home?15000000ULL:180000000ULL) || ((t->mask&24) && !f1_online(now))) {
            fault=(t->mask&24)?8:7; link_fault(); cancel_tasks(5,1); break;
        }
        if ((t->mask&7)&busy) continue;
        if ((t->mask&24) && (pending.active || f1_data[12]!=0 || !f1_data[13] || f1_state_received<=t->start+3000)) continue;
        if ((t->mask&24) && t->home && now-t->start<5000000) continue;
        uint32_t id=t->id; uint8_t mask=t->mask,type=t->home?4:2; t->mask=0; event(id,mask,type,0);
    }
    if (zero_pending && (!f1_online(now) || f1_data[12]==5 || now-pending.sent>15000000)) {
        fault=3; link_fault();
    }
    if (zero_pending && !pending.active && f1_data[13] && f1_data[12]==0 && now-pending.sent>5000000ULL) {
        uint8_t data[12]; wire_put32(data,config); memcpy(data+4,f1_data+100,8);
        event(0,24,7,0); finish_zero(0,data,12);
    }
    if (now-cycle>=5000) { cycle=now; make_snapshot(now); }
    for (unsigned i=0;i<2;i++) {
        Link *l=&links[i]; if (!l->session) continue;
        if (l->rate && now-l->last_state>=1000000U/l->rate) {
            uint8_t state[96]; state_for(state,l); l->last_state=now;
            board_port_send(&l->port,0x81,(uint16_t)sample,state,96,1);
        }
        uint32_t next=l->ack+1;
        if (next<oldest_event) next=oldest_event;
        if (next<=event_id && now-l->last_event>=100000) {
            uint8_t p[40]; memcpy(p,events[(next-1)%64],40); wire_put32(p+8,l->session);
            if (board_port_send(&l->port,0x90,(uint16_t)next,p,40,0)) {
                l->last_event=now; l->sent_event=next;
            }
        }
    }
}
