#include "f1_link.h"
#include "internal.h"
#include "mpu6050.h"
#include "gimbal_test.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

static BoardPort port;
static Pose pose;
static uint64_t boot, last_state, last_feedback, last_contact, home_start;
static uint32_t config=1;
static uint8_t phase, home_pending, servicing;
static uint16_t max_seq;
typedef struct { uint16_t seq,n; uint8_t cmd,result,data[16]; } Cached;
static Cached cache[16];
static uint8_t cache_next;
static uint8_t pending_cmd, pending_data[16];
static uint16_t pending_seq, pending_size;
static void publish_state(uint64_t now);

static void feedback(unsigned axis, uint16_t raw, uint8_t valid)
{
    pose_servo(&pose,axis,raw,board_us(),valid);
}
static void reply(uint8_t cmd, uint16_t seq, uint8_t result)
{
    uint8_t data[12]={0}; wire_put64(data,boot); data[8]=cmd; data[9]=result;
    board_port_send(&port,F1_REPLY,seq,data,sizeof(data),0);
}
static void receive(void *ctx, uint8_t cmd, uint16_t seq, const uint8_t *data, uint16_t n, uint64_t tick)
{
    (void)ctx;
    if (cmd==F1_INFO && n==0) { last_contact=tick; reply(cmd,seq,boot ? 0 : 9); return; }
    if (n<8 || wire_u64(data)!=boot || !boot) { reply(cmd,seq,5); return; }
    if (cmd!=F1_READY && cmd!=F1_GO && cmd!=F1_ZERO) { reply(cmd,seq,6); return; }
    last_contact=tick;
    for (unsigned i=0;i<16;i++) if (cache[i].seq==seq && seq) {
        int same=cache[i].cmd==cmd && cache[i].n==n && n<=16 && !memcmp(cache[i].data,data,n);
        reply(cmd,seq,same ? cache[i].result : 8); return;
    }
    if (!seq || seq<=max_seq) { reply(cmd,seq,10); return; }
    /* The vendor bus is synchronous. Defer command execution until its current
     * transaction ends. */
    if (servicing) {
        if (pending_cmd) { reply(cmd,seq,2); return; }
        if (n>sizeof(pending_data)) { reply(cmd,seq,3); return; }
        pending_cmd=cmd; pending_seq=seq; pending_size=n; memcpy(pending_data,data,n); return;
    }
    uint8_t result=0;
    if (cmd==F1_READY && n==8) {
        if (Gimbal_State()==1 || Gimbal_State()==2 || home_pending) result=2;
        else {
            phase=2;
            pose_begin_home(&pose); Gimbal_SetPoseReady(0);
            if (!Gimbal_Ready()) result=9;
            else { phase=2; home_pending=1; home_start=board_us(); result=1; }
        }
    } else if (cmd==F1_ZERO && n==8) {
        if (!pose.home_confirmed || Gimbal_State()!=0 || home_pending ||
            abs((int)pose.servo_raw[0]-1881)>12 || abs((int)pose.servo_raw[1]-2405)>12) result=7;
        else {
            pose_begin_home(&pose); pose_home_confirmed(&pose,board_us());
            Gimbal_SetPoseReady(0); home_pending=1; phase=3; home_start=board_us(); result=1;
        }
    } else if (cmd==F1_GO && n==16) {
        if (!pose.zero_valid || home_pending) result=7;
        else if (Gimbal_State()!=0) result=2;
        else {
            phase=1;
            if (!Gimbal_Go((int32_t)wire_u32(data+8),(int32_t)wire_u32(data+12))) result=9;
            else result=1;
        }
    } else result=6;
    if (n<=16) {
        Cached *c=&cache[cache_next++%16]; c->seq=seq; c->cmd=cmd; c->n=n; c->result=result;
        memcpy(c->data,data,n); max_seq=seq;
    }
    reply(cmd,seq,result);
}
void F1_Link_Init(UART_HandleTypeDef *uart)
{
    pose_init(&pose); boot=board_boot_id();
    board_port_init(&port,uart,receive,0,30);
    Gimbal_SetFeedback(feedback); Gimbal_SetPoseReady(0);
    if (!MPU6050_Init()) wire_count(&pose.i2c_errors);
    last_contact=board_us();
}
void F1_Link_Rx(UART_HandleTypeDef *uart) { board_port_rx(&port,uart); }
void F1_Link_Error(UART_HandleTypeDef *uart) { board_port_error(&port,uart); }
void F1_Link_TxDone(UART_HandleTypeDef *uart) { board_port_tx_done(&port,uart); }
void F1_Service(void)
{
    if (servicing) return;
    servicing=1;
    board_port_poll(&port); MPU6050_Poll(&pose,board_us());
    publish_state(board_us());
    servicing=0;
}
void F1_Link_Poll(void)
{
    F1_Service();
    if (pending_cmd) {
        uint8_t cmd=pending_cmd; pending_cmd=0;
        receive(0,cmd,pending_seq,pending_data,pending_size,board_us());
    }
    uint64_t now=board_us();
    if (now-last_feedback>=10000) { last_feedback=now; Gimbal_ReadFeedback(); now=board_us(); }
    uint8_t state=Gimbal_State();
    if (home_pending && phase==2 && state==0) { pose_home_confirmed(&pose,now); phase=3; }
    if (home_pending && (state==5 || now-home_start>15000000ULL)) {
        pose_abort(&pose); home_pending=0; phase=5;
        (void)Gimbal_CancelMotion(); Gimbal_SetPoseReady(0);
    } else if (state==5 && phase!=5) {
        (void)Gimbal_CancelMotion(); phase=5;
        if (!pose.zero_valid) Gimbal_SetPoseReady(0);
    }
    if (home_pending && phase==3 && pose_calibrate(&pose,now)) {
        home_pending=0; phase=0; ++config; Gimbal_SetPoseReady(1);
    }
    if (!home_pending && phase!=5) phase=state;
    if ((phase==1 || home_pending) && now-last_contact>1000000ULL) {
        pose_abort(&pose); home_pending=0;
        (void)Gimbal_CancelMotion(); Gimbal_SetPoseReady(0); phase=5;
    }
    publish_state(now);
}
static void publish_state(uint64_t now)
{
    pose_fuse(&pose,now);
    if (now-last_state>=5000) {
        last_state=now;
        uint8_t p[F1_STATE_BYTES]={0};
        wire_put64(p,boot); wire_put32(p+8,pose.sample_seq);
        p[12]=phase; p[13]=pose.zero_valid; p[14]=pose.home_confirmed; p[15]=pose.source;
        wire_put64(p+16,pose.sensor_valid ? pose.imu_us : 0);
        for (unsigned i=0;i<2;i++) {
            wire_put64(p+24+8*i,(pose.servo_valid&(1U<<i)) ? pose.servo_us[i] : 0);
            wire_put32(p+40+4*i,(uint32_t)pose.angle[i]);
            wire_put32(p+48+4*i,(uint32_t)pose.servo[i]); wire_put16(p+56+2*i,pose.servo_raw[i]);
        }
        wire_put64(p+60,pose.imu_us); wire_put32(p+68,pose.sample_seq); wire_put32(p+72,config);
        for (unsigned i=0;i<3;i++) {
            wire_put16(p+76+2*i,(uint16_t)pose.accel[i]); wire_put16(p+82+2*i,(uint16_t)pose.gyro[i]);
            wire_put32(p+108+4*i,(uint32_t)(int32_t)lroundf(pose.bias[i]*1000000));
        }
        wire_put16(p+88,(uint16_t)pose.temperature); p[90]=pose.sensor_valid;
        wire_put32(p+92,pose.i2c_errors); wire_put32(p+96,pose.missed);
        wire_put32(p+100,(uint32_t)(int32_t)lroundf(pose.zero_pitch*1000));
        wire_put32(p+104,(uint32_t)(int32_t)lroundf(pose.zero_yaw*1000)); wire_put32(p+120,config);
        wire_put32(p+124,(uint32_t)now);
        board_port_send(&port,F1_STATE,(uint16_t)pose.sample_seq,p,sizeof(p),1);
    }
}
