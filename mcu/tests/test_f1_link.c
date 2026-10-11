#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../firmware/yuntai/Core/Src/f1_link.c"

static uint64_t now=1000;
static uint8_t mechanical,can_move,sensor_ok=1,last_result;
static unsigned go_calls,cancel_calls;
static GimbalFeedback observe;
uint64_t board_us(void) {return now;}
uint64_t board_boot_id(void) {return 77;}
uint64_t board_device_id(void) {return 99;}
void board_port_init(BoardPort *p,UART_HandleTypeDef *u,WireReceive cb,void *c,uint16_t t)
{(void)u;memset(p,0,sizeof(*p));wire_init(&p->parser,t,cb,c);}
void board_port_rx(BoardPort *p,UART_HandleTypeDef *u){(void)p;(void)u;}
void board_port_error(BoardPort *p,UART_HandleTypeDef *u){(void)p;(void)u;}
void board_port_tx_done(BoardPort *p,UART_HandleTypeDef *u){(void)p;(void)u;}
void board_port_poll(BoardPort *p){(void)p;}
int board_port_send(BoardPort *p,uint8_t cmd,uint16_t seq,const uint8_t *b,uint16_t n,int s)
{(void)p;(void)seq;(void)n;(void)s;if(cmd==F1_REPLY)last_result=b[9];return 1;}
int MPU6050_Init(void){return sensor_ok;}
void MPU6050_Poll(Pose *p,uint64_t tick)
{int16_t a[3]={0,0,16384},g[3]={0,0,0};if(sensor_ok)pose_sample(p,a,g,0,tick);else p->sensor_valid=0;}
void Gimbal_SetFeedback(GimbalFeedback p){observe=p;}
void Gimbal_SetPoseReady(uint8_t v){can_move=v;}
uint8_t Gimbal_State(void){return mechanical;}
uint8_t Gimbal_Ready(void){mechanical=2;return 1;}
uint8_t Gimbal_Go(int32_t p,int32_t y){(void)p;(void)y;assert(can_move);mechanical=1;++go_calls;return 1;}
uint8_t Gimbal_CancelMotion(void){mechanical=0;++cancel_calls;return 1;}
void Gimbal_ReadFeedback(void){observe(0,1881,1);observe(1,2405,1);}
static void request(uint8_t cmd,uint16_t seq)
{uint8_t p[16]={0};wire_put64(p,boot);receive(0,cmd,seq,p,cmd==F1_GO?16:8,now);}
static void advance(unsigned milliseconds)
{
    for(unsigned i=0;i<milliseconds;i+=5){now+=5000;last_contact=now;F1_Link_Poll();}
}
int main(void)
{
    UART_HandleTypeDef uart;F1_Link_Init(&uart);
    request(F1_GO,1);assert(last_result==7 && !go_calls);
    request(F1_READY,2);assert(last_result==1 && !can_move);
    advance(6000);assert(!pose.zero_valid); /* issuance is not arrival */
    mechanical=0;advance(5);assert(home_pending && phase==3);
    advance(4990);assert(!pose.zero_valid && !can_move);
    request(F1_GO,3);assert(last_result==7);
    advance(30);assert(pose.zero_valid && can_move && !home_pending);
    request(F1_GO,4);assert(last_result==1 && go_calls==1);
    request(F1_GO,4);assert(last_result==1 && go_calls==1);
    uint64_t contact=last_contact;
    servicing=1;request(0x23,5);servicing=0;
    assert(last_result==6 && last_contact==contact && !pending_cmd);
    assert(mechanical==1 && !cancel_calls && pose.zero_valid);
    now+=1000001;F1_Link_Poll();
    assert(phase==5 && cancel_calls==1 && !can_move && pose.zero_valid);
    request(F1_READY,6);mechanical=0;advance(20);
    sensor_ok=0;advance(5100);assert(!pose.zero_valid && !can_move);
    request(0x23,7);assert(last_result==6 && home_pending && !pose.zero_valid);
    advance(10000);assert(phase==5 && !home_pending && cancel_calls==2);
    puts("F1 link: zero delay, motion gate, retry, retired opcode and local timeout passed");
    return 0;
}
