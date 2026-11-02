#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../firmware/yuntai/Core/Src/mpu6050.c"

static uint8_t registers[256],read_failure,corrupt_configuration;
static unsigned writes;
void HAL_GPIO_Init(unsigned port,GPIO_InitTypeDef *gpio)
{ assert(port==GPIOB && gpio->Pin==(GPIO_PIN_6|GPIO_PIN_7) && gpio->Mode==GPIO_MODE_AF_OD); }
void HAL_Delay(uint32_t ms) { assert(ms==100); }
HAL_StatusTypeDef HAL_I2C_Init(I2C_HandleTypeDef *handle)
{ assert(handle->Instance==I2C1 && handle->Init.ClockSpeed==400000);return HAL_OK; }
HAL_StatusTypeDef HAL_I2C_Mem_Read(I2C_HandleTypeDef *h,uint16_t address,uint16_t reg,
    uint16_t size,uint8_t *data,uint16_t n,uint32_t timeout)
{
    (void)h;assert(address==0xd0 && size==I2C_MEMADD_SIZE_8BIT && timeout==2);
    if(read_failure)return HAL_ERROR;
    memcpy(data,registers+reg,n);
    if(corrupt_configuration && reg==0x1a)data[0]^=1;
    if(reg==0x3a)registers[reg]=0;
    return HAL_OK;
}
HAL_StatusTypeDef HAL_I2C_Mem_Write(I2C_HandleTypeDef *h,uint16_t address,uint16_t reg,
    uint16_t size,uint8_t *data,uint16_t n,uint32_t timeout)
{
    (void)h;assert(address==0xd0 && size==I2C_MEMADD_SIZE_8BIT && timeout==2 && n==1);
    registers[reg]=*data;++writes;return HAL_OK;
}
int main(void)
{
    Pose p;pose_init(&p);
    registers[0x75]=0x69;assert(!MPU6050_Init() && !writes);
    registers[0x75]=0x68;corrupt_configuration=1;assert(!MPU6050_Init());
    MPU6050_Poll(&p,5000);assert(!p.sensor_valid && !p.sample_seq);
    corrupt_configuration=0;assert(MPU6050_Init());
    assert(registers[0x6b]==1 && registers[0x19]==4 && registers[0x1a]==3);
    assert(!registers[0x1b] && !registers[0x1c] && !registers[0x23] && !registers[0x6a]);
    /* One burst must preserve big-endian sensor words, including signed gyro. */
    registers[0x3a]=1;registers[0x3f]=0x40;
    registers[0x43]=0xff;registers[0x44]=0x7d;
    MPU6050_Poll(&p,10000);assert(p.sample_seq==1 && p.imu_us==10000 && p.sensor_valid);
    assert(p.accel[2]==16384 && p.gyro[0]==-131);
    MPU6050_Poll(&p,15000);assert(p.sample_seq==1 && p.imu_us==10000);
    read_failure=1;MPU6050_Poll(&p,20000);
    assert(!p.sensor_valid && p.i2c_errors==1 && p.sample_seq==1 && p.imu_us==10000);
    puts("MPU6050: identity, configuration readback, fresh burst, signed data and I2C failure passed");
    return 0;
}
