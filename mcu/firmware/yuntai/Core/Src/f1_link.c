#include "f1_link.h"
#include "internal.h"
#include "pose.h"
#include "gimbal_test.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

static BoardPort port;
static Pose pose;
static uint64_t boot, last_state, last_feedback, last_contact, home_start;
/* 2026-10-22：进入故障态 phase=5 的时刻，以及上一次尝试清驱动失败态的时刻 */
static uint64_t phase5_since, phase5_try;
/* 诊断（2026-10-22）：F1 累计收到 F4 的 INFO 帧数，低 8 位写在 STATE 第 91 字节。
 * 若该值在增长，说明 F4→F1 方向通；恒为 0 说明 F1 一帧都没收到。 */
static uint32_t info_count;

/* 诊断（2026-10-22）：启动时把 PA10（USART1_RX）临时当普通输入，扫描 1 秒看有没有电平
 * 活动。F4 每 200 ms 发一帧 INFO（10 字节），1 秒内应有约 5 帧，必然能扫到跳变。
 * 必须在 MX_USART1_UART_Init() 之前调用（放在 main.c 的 USER CODE SysInit 区）。
 * 结果写进 STATE 第 91 字节的 bit6。 */
uint8_t f1_pa10_active;
void F1_Pin_ScanOnce(void)
{
    __HAL_RCC_GPIOA_CLK_ENABLE();
    GPIO_InitTypeDef g = {0};
    g.Pin = GPIO_PIN_10;
    g.Mode = GPIO_MODE_INPUT;
    g.Pull = GPIO_PULLUP;
    HAL_GPIO_Init(GPIOA, &g);
    HAL_Delay(5);

    uint8_t prev = (uint8_t)((GPIOA->IDR >> 10) & 1U);
    uint32_t t0 = HAL_GetTick();
    while (HAL_GetTick() - t0 < 1000U)
    {
        uint8_t v = (uint8_t)((GPIOA->IDR >> 10) & 1U);
        if (v != prev) { f1_pa10_active = 1; break; }
        prev = v;
    }
}
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
    if (cmd==F1_INFO && n==0) { last_contact=tick; ++info_count; reply(cmd,seq,boot ? 0 : 9); return; }
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
            abs((int)pose.servo_raw[0]-(int)GIMBAL_CENTER_PITCH_RAW)>(int)GIMBAL_POSITION_TOLERANCE ||
            abs((int)pose.servo_raw[1]-(int)GIMBAL_CENTER_YAW_RAW)>(int)GIMBAL_POSITION_TOLERANCE) result=7;
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
    /* MPU6050 pose fusion is not used: pitch/yaw come from the servo feedback
     * only, so no I2C init and no sensor_valid path exists in this build. */
    last_contact=board_us();
}
void F1_Link_Rx(UART_HandleTypeDef *uart) { board_port_rx(&port,uart); }
void F1_Link_Error(UART_HandleTypeDef *uart) { board_port_error(&port,uart); }
void F1_Link_TxDone(UART_HandleTypeDef *uart) { board_port_tx_done(&port,uart); }
void F1_Service(void)
{
    if (servicing) return;
    servicing=1;
    board_port_poll(&port);
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
        pose_abort(&pose); home_pending=0; phase=5; phase5_since=now;
        (void)Gimbal_CancelMotion(); Gimbal_SetPoseReady(0);
    } else if (state==5 && phase!=5) {
        (void)Gimbal_CancelMotion(); phase=5; phase5_since=now;
        if (!pose.zero_valid) Gimbal_SetPoseReady(0);
    }
    if (home_pending && phase==3 && pose_calibrate(&pose,now)) {
        home_pending=0; phase=0; ++config; Gimbal_SetPoseReady(1);
    }
    if (!home_pending && phase!=5) phase=state;
    if ((phase==1 || home_pending) && now-last_contact>1000000ULL) {
        pose_abort(&pose); home_pending=0;
        (void)Gimbal_CancelMotion(); Gimbal_SetPoseReady(0); phase=5; phase5_since=now;
    }
    /* 2026-10-22：故障态自愈。原来 phase=5 一旦进入就无法退出，只能靠复位；
     * 链路一次几十毫秒抖动就会把整个云台永久锁死（4_Link_Poll 见到 phase==5
     * 会取消任何云台运动，连 /home 都做不了）。这里改为：
     *   - 链路恢复正常（1 秒内收到过 INFO）且已持续 1 秒；
     *   - 没有进行中的回正请求，且驱动本身无故障（Gimbal_State()==0）；
     * 就自动解除故障态，并恢复姿态可用标志。 */
    if (phase==5) {
        if (!phase5_since) phase5_since=now;
        else if (now-last_contact<200000ULL && now-phase5_since>1000000ULL && !home_pending) {
            /* 先尝试清掉驱动自身的失败标志（failed -> Gimbal_State()==5），
             * 每 500 ms 只尝试一次，避免在总线上反复刷取消命令。 */
            if (Gimbal_State()!=0 && now-phase5_try>500000ULL) {
                phase5_try=now;
                (void)Gimbal_CancelMotion();
            }
            if (Gimbal_State()==0) {
                phase=0; phase5_since=0;
                if (pose.zero_valid) Gimbal_SetPoseReady(1);
            }
        } else if (now-last_contact>=200000ULL) {
            phase5_since=now;   /* 链路又不通了，重新计时 */
        }
    } else {
        phase5_since=0;
    }
    publish_state(now);
}
static void publish_state(uint64_t now)
{
    pose_fuse(&pose,now);
    /* 2026-10-21：恢复 5 ms（实际受 board.c 的 7.5 ms 发送门限限制，约 133 帧/s）。
     * 之前改成 10 ms 是基于"460800 下中断过载丢帧"的误判——真正的根因是 F1 与 F4
     * 之间 TX/RX 接反。10 ms 会让 F4 侧 POSE_STALE_US(20 ms) 的余量不足，表现为
     * STATE 里 pitch/yaw 有效位闪烁，并可能误触 f1_feedback_fresh() 失败。 */
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
        p[91]=(uint8_t)((info_count&0x3FU) |
                        (f1_pa10_active ? 0x40U : 0U) |
                        (__HAL_UART_GET_FLAG(port.uart,UART_FLAG_ORE) ? 0x80U : 0U));
        /* 诊断（2026-10-22）：把 USART1 的接收统计一并回传，定位"没收到"还是"收到被丢"。
         * 92..95 原本属 IMU 的 i2c_errors（IMU 已移除，恒 0）。 */
        p[92]=(uint8_t)port.rx_total;
        p[93]=(uint8_t)port.overrun;
        p[94]=(uint8_t)port.parser.crc_errors;
        p[95]=(uint8_t)port.parser.timeouts;
        /* 96..99 原属 IMU 的 missed：改放 USART1 的接收控制状态。
         * 96 = RxState，97 = CR1 低 8 位（bit5 即 RXNEIE），98/99 = failed / ErrorCode */
        p[96]=(uint8_t)port.uart->RxState;
        p[97]=(uint8_t)(port.uart->Instance->CR1 & 0xFFU);
        p[98]=port.failed;
        p[99]=(uint8_t)port.uart->ErrorCode;
        /* 2026-10-22：108/109 原属已废弃的 IMU 偏置，改放舵机总线就绪失败步号与驱动状态 */
        p[108]=Gimbal_LastFailStep();
        p[109]=Gimbal_State();
        /* 2026-10-22：定位"回执已接受但不动作"。
         * 112 就绪标志位，113/114 两轴 phase，116/118 两轴目标 raw。 */
        p[112]=Gimbal_DebugFlags();
        p[113]=Gimbal_AxisPhaseId(0U);
        p[114]=Gimbal_AxisPhaseId(1U);
        wire_put16(p+116,Gimbal_TargetRaw(0U));
        wire_put16(p+118,Gimbal_TargetRaw(1U));
        board_port_send(&port,F1_STATE,(uint16_t)pose.sample_seq,p,sizeof(p),1);
    }
}
