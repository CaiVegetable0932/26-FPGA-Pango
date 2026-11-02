#include "pose.h"
#include "../../config/pose_config.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define RAD_TO_DEG 57.2957795131f
/* Servo-only centering reference in raw counts. 2026-11-02: yaw 2405 -> 2354.
 * This machine's yaw servo rests at raw 2353~2354 at the visual zero with no
 * mechanical stop; the old 2405 constant made servo_centered() unreachable, so
 * pose_calibrate() never confirmed a home and F4 latched fault=8 on its 15 s
 * timeout. Keep in sync with GIMBAL_CENTER_*_RAW in firmware/yuntai. */
static const uint16_t center[2]={1881,2354};

/* Servo-only zeroing tolerance in raw counts. Must match
 * GIMBAL_POSITION_TOLERANCE (firmware/yuntai/Core/Inc/gimbal_test.h): the bus
 * servos repeat to ~+-20 counts, and measured settling was as far as 31 counts,
 * so a tighter window would never confirm. 2026-10-22: 24 -> 32. */
#define POSE_CENTER_TOL_RAW 32
static float wrap(float x) { while (x>180) x-=360; while (x<=-180) x+=360; return x; }
int32_t pose_delta(int32_t x) { while (x>180000) x-=360000; while (x<=-180000) x+=360000; return x; }
void pose_init(Pose *p)
{
    memset(p,0,sizeof(*p)); p->servo_weight=POSE_SERVO_WEIGHT; p->imu_weight=POSE_IMU_WEIGHT;
    p->disagreement_mdeg=POSE_DISAGREEMENT_MDEG; p->stale_us=POSE_STALE_US;
    p->q_bi[0]=POSE_Q_BI_W; p->q_bi[1]=POSE_Q_BI_X;
    p->q_bi[2]=POSE_Q_BI_Y; p->q_bi[3]=POSE_Q_BI_Z;
    float norm=0; for (unsigned i=0;i<4;i++) norm+=p->q_bi[i]*p->q_bi[i];
    if (fabsf(norm-1)>0.001f) { memset(p->q_bi,0,sizeof(p->q_bi)); }
}
void pose_begin_home(Pose *p)
{
    p->zero_valid=p->home_confirmed=p->settling=0;
    p->stable_samples=0; memset(p->bias_sum,0,sizeof(p->bias_sum));
}
void pose_home_confirmed(Pose *p, uint64_t tick)
{
    p->home_confirmed=p->settling=1; p->settle_us=tick;
    p->stable_samples=0; memset(p->bias_sum,0,sizeof(p->bias_sum));
}
void pose_abort(Pose *p)
{
    if (p->settling || !p->home_confirmed) p->zero_valid=0;
    p->settling=0; p->stable_samples=0;
}

/* Rotate sensor vectors into the platform axes before extracting attitude. */
static void rotate(const float q[4], const float in[3], float out[3])
{
    float tx=2*(q[2]*in[2]-q[3]*in[1]);
    float ty=2*(q[3]*in[0]-q[1]*in[2]);
    float tz=2*(q[1]*in[1]-q[2]*in[0]);
    out[0]=in[0]+q[0]*tx+q[2]*tz-q[3]*ty;
    out[1]=in[1]+q[0]*ty+q[3]*tx-q[1]*tz;
    out[2]=in[2]+q[0]*tz+q[1]*ty-q[2]*tx;
}

void pose_sample(Pose *p, const int16_t a[3], const int16_t g[3], int16_t temperature, uint64_t tick)
{
    float ai[3], gi[3], ab[3], gb[3];
    float dt=p->imu_us ? (float)(tick-p->imu_us)*1e-6f : 0;
    for (unsigned i=0;i<3;i++) { ai[i]=a[i]/16384.0f; gi[i]=g[i]/131.0f; }
    rotate(p->q_bi,ai,ab); rotate(p->q_bi,gi,gb);
    float norm=sqrtf(ab[0]*ab[0]+ab[1]*ab[1]+ab[2]*ab[2]);
    float ap=atan2f(-ab[0],sqrtf(ab[1]*ab[1]+ab[2]*ab[2]))*RAD_TO_DEG;
    float ar=atan2f(ab[1],ab[2])*RAD_TO_DEG;
    int gap=p->imu_us && (dt<=0 || dt>0.02f);
    if (p->imu_us && dt>0.0075f) {
        uint32_t lost=(uint32_t)(dt/0.005f)-1;
        p->missed=UINT32_MAX-p->missed<lost ? UINT32_MAX : p->missed+lost;
    }
    if (gap) p->stable_samples=0;
    if (!p->imu_us) { p->pitch=ap; p->roll=ar; p->yaw=0; }
    else if (!gap) {
        /* Euler-rate kinematics avoid treating sensor Z as yaw when tilted. */
        float r=p->roll/RAD_TO_DEG, v=p->pitch/RAD_TO_DEG;
        float sr=sinf(r), cr=cosf(r), cv=cosf(v);
        float gx=gb[0]-p->bias[0], gy=gb[1]-p->bias[1], gz=gb[2]-p->bias[2];
        if (fabsf(cv)>0.087f) {
            p->roll=wrap(p->roll+(gx+sinf(v)/cv*(gy*sr+gz*cr))*dt);
            p->pitch+=(gy*cr-gz*sr)*dt;
            p->yaw=wrap(p->yaw+(gy*sr+gz*cr)/cv*dt);
        }
        /* 0.5 s gravity correction; reject large translational acceleration. */
        if (norm>0.9f && norm<1.1f) {
            float k=dt/(0.5f+dt);
            p->pitch+=k*(ap-p->pitch); p->roll=wrap(p->roll+k*wrap(ar-p->roll));
        }
    }
    p->sensor_valid=(uint8_t)(!gap && norm>0.2f && fabsf(p->pitch)<85);
    if (p->q_bi[0]==0 && p->q_bi[1]==0 && p->q_bi[2]==0 && p->q_bi[3]==0) p->sensor_valid=0;
    for (unsigned i=0;i<3;i++)
        if (abs((int)g[i])>=32760 || abs((int)a[i])>=32760) p->sensor_valid=0;
    memcpy(p->accel,a,sizeof(p->accel)); memcpy(p->gyro,g,sizeof(p->gyro));
    p->temperature=temperature; p->imu_us=tick; ++p->sample_seq;
    if (p->home_confirmed) {
        int stable=p->sensor_valid && norm>0.97f && norm<1.03f && p->servo_valid==3;
        for (unsigned i=0;i<3;i++) stable &= fabsf(gb[i]-p->bias[i])<POSE_STABLE_RATE_DPS;
        for (unsigned i=0;i<2;i++) stable &= tick-p->servo_us[i]<=p->stale_us &&
            abs((int)p->servo_raw[i]-(int)center[i])<=POSE_CENTER_TOL_RAW;
        if (!stable || gap) {
            p->settle_us=tick; p->stable_samples=0; memset(p->bias_sum,0,sizeof(p->bias_sum));
        } else if (p->stable_samples<2000) {
            for (unsigned i=0;i<3;i++) p->bias_sum[i]+=gb[i];
            ++p->stable_samples;
        }
    }
}
/* Servo-only zeroing: the two axes must stay inside the homing tolerance. */
static int servo_centered(const Pose *p)
{
    if (p->servo_valid!=3) return 0;
    for (unsigned i=0;i<2;i++)
        if (abs((int)p->servo_raw[i]-(int)center[i])>POSE_CENTER_TOL_RAW) return 0;
    return 1;
}

void pose_servo(Pose *p, unsigned axis, uint16_t raw, uint64_t tick, int valid)
{
    if (axis>1) return;
    if (!valid || raw>4095) {
        p->servo_valid&=(uint8_t)~(1U<<axis);
        /* Lost or failed feedback restarts the servo-only stable window. */
        if (p->settling && p->home_confirmed) p->settle_us=tick;
        return;
    }
    p->servo_raw[axis]=raw;
    p->servo[axis]=(int32_t)lroundf(((int32_t)raw-center[axis])*270000.0f/4095.0f);
    if (abs(p->servo[axis])>60792) {
        p->servo_valid&=(uint8_t)~(1U<<axis);
        if (p->settling && p->home_confirmed) p->settle_us=tick;
        return;
    }
    p->servo_us[axis]=tick; p->servo_valid|=(uint8_t)(1U<<axis);
    /* Servo feedback drives the published sample counter when no IMU is used. */
    ++p->sample_seq;
    /* Any axis leaving the center tolerance restarts the stable window. */
    if (p->settling && p->home_confirmed && !servo_centered(p)) p->settle_us=tick;
}
int pose_calibrate(Pose *p, uint64_t tick)
{
    if ((!p->settling && !p->zero_valid) || !p->home_confirmed) return 0;
    if (tick-p->servo_us[0]>p->stale_us || tick-p->servo_us[1]>p->stale_us) return 0;
    if (tick-p->settle_us<POSE_WAIT_US) return 0;

    if (p->sensor_valid) {
        /* IMU path: gyro bias and absolute attitude zero, unchanged. */
        if (p->servo_valid!=3 || p->stable_samples<900 || tick-p->imu_us>p->stale_us) return 0;
        for (unsigned i=0;i<3;i++) p->bias[i]=(float)(p->bias_sum[i]/p->stable_samples);
        p->zero_pitch=p->pitch; p->zero_yaw=p->yaw;
    } else {
        /* Servo-only path: fresh, still-centered feedback confirms the zero.
         * No gyro bias and no attitude reference exist in this mode. */
        if (!servo_centered(p)) return 0;
        memset(p->bias,0,sizeof(p->bias));
        p->zero_pitch=0.0f; p->zero_yaw=0.0f;
    }
    p->zero_valid=1; p->settling=0;
    return 1;
}
void pose_fuse(Pose *p, uint64_t tick)
{
    p->source=0;
    for (unsigned i=0;i<2;i++) {
        p->angle[i]=0;
        if (!p->zero_valid || !(p->servo_valid&(1U<<i)) || tick-p->servo_us[i]>p->stale_us) continue;
        int32_t servo=p->servo[i];
        int32_t imu=(int32_t)lroundf(1000*(i ? wrap(p->yaw-p->zero_yaw) : p->pitch-p->zero_pitch));
        int32_t delta=pose_delta(imu-servo);
        uint64_t skew=p->imu_us>p->servo_us[i] ? p->imu_us-p->servo_us[i] : p->servo_us[i]-p->imu_us;
        unsigned source=1;
        p->angle[i]=servo;
        if (p->sensor_valid && tick-p->imu_us<=p->stale_us && skew<=p->stale_us &&
            (uint32_t)abs(delta)<=p->disagreement_mdeg) {
            int64_t n=(int64_t)p->imu_weight*delta;
            int32_t weights=p->servo_weight+p->imu_weight;
            p->angle[i]=servo+(int32_t)((n+(n<0?-weights/2:weights/2))/weights);
            source=2;
        }
        p->source|=(uint8_t)(source<<(2*i));
    }
}
