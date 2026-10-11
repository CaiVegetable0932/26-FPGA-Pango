#include <stdint.h>
typedef void (*GimbalFeedback)(unsigned,uint16_t,uint8_t);
void Gimbal_SetFeedback(GimbalFeedback);
void Gimbal_SetPoseReady(uint8_t);
uint8_t Gimbal_State(void);
uint8_t Gimbal_Ready(void);
uint8_t Gimbal_Go(int32_t,int32_t);
uint8_t Gimbal_CancelMotion(void);
void Gimbal_ReadFeedback(void);
