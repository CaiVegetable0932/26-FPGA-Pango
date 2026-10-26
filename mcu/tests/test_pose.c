#include "pose.h"
#include <assert.h>
#include <stdio.h>

static void stationary(Pose *p, uint64_t tick)
{
    int16_t a[3]={0,0,16384},g[3]={0,0,20};
    pose_servo(p,0,1881,tick,1); pose_servo(p,1,2405,tick,1);
    pose_sample(p,a,g,0,tick);
}
int main(void)
{
    Pose p; pose_init(&p); pose_begin_home(&p);
    for (uint64_t t=5000;t<=6000000;t+=5000) stationary(&p,t);
    assert(!pose_calibrate(&p,6000000));
    pose_home_confirmed(&p,6000000);
    for (uint64_t t=6005000;t<=10995000;t+=5000) stationary(&p,t);
    assert(!pose_calibrate(&p,10995000));
    stationary(&p,11000000); assert(pose_calibrate(&p,11000000));
    pose_fuse(&p,11000000); assert(p.source==10 && p.angle[0]==0 && p.angle[1]==0);
    p.pitch=p.zero_pitch+1; pose_fuse(&p,11000000); assert(p.angle[0]==100);
    p.pitch=p.zero_pitch+20; pose_fuse(&p,11000000); assert(p.angle[0]==0 && (p.source&3)==1);
    p.sensor_valid=0; pose_fuse(&p,11000000); assert(p.source==5);
    pose_fuse(&p,11020001); assert(!p.source);
    pose_begin_home(&p); stationary(&p,12000000); pose_home_confirmed(&p,12000000);
    for (uint64_t t=12005000;t<14000000;t+=5000) stationary(&p,t);
    pose_abort(&p); assert(!pose_calibrate(&p,19000000) && !p.zero_valid);
    assert(pose_delta(359000)==-1000);
    /* Movement during settling must restart the five-second stable window. */
    pose_init(&p);pose_home_confirmed(&p,1000);
    for(uint64_t t=5000;t<=4000000;t+=5000)stationary(&p,t);
    int16_t a[3]={0,0,16384},g[3]={0,0,393};
    pose_sample(&p,a,g,0,4005000);
    for(uint64_t t=4010000;t<=9000000;t+=5000)stationary(&p,t);
    assert(!pose_calibrate(&p,9000000));stationary(&p,9005000);
    assert(pose_calibrate(&p,9005000));
    /* At 60-degree pitch, body-Z rate must not be mistaken for yaw rate. */
    pose_init(&p);p.pitch=60;p.imu_us=1000;
    int16_t tilted[3]={-14189,0,8192},yaw_rate[3]={0,0,131};
    pose_sample(&p,tilted,yaw_rate,0,6000);
    assert(p.yaw>0.009f && p.yaw<0.011f);
    pose_servo(&p,0,4095,6000,1);assert(!(p.servo_valid&1));
    /* Current servo-only profile: both axes remain within the 24-count band
     * for five seconds. A failed sample restarts that window, and stale data
     * cannot remain a valid angle just because STATE is still being sent. */
    pose_init(&p);pose_home_confirmed(&p,1000);
    for(uint64_t t=1000;t<=4001000;t+=10000){pose_servo(&p,0,1905,t,1);pose_servo(&p,1,2381,t,1);}
    assert(!pose_calibrate(&p,4001000));pose_servo(&p,0,0,4001000,0);
    for(uint64_t t=4011000;t<=8991000;t+=10000){pose_servo(&p,0,1905,t,1);pose_servo(&p,1,2381,t,1);}
    assert(!pose_calibrate(&p,8991000));
    pose_servo(&p,0,1905,9001000,1);pose_servo(&p,1,2381,9001000,1);
    assert(pose_calibrate(&p,9001000));pose_fuse(&p,9001000);
    assert(p.source==5 && p.angle[0]==1582 && p.angle[1]==-1582 && !p.sensor_valid);
    pose_fuse(&p,9021001);assert(p.source==0);
    puts("pose: encoder-only zeroing/tolerance/stale and retained IMU reference tests passed");
    return 0;
}
