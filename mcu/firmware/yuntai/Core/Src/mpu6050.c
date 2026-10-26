#include "mpu6050.h"
#include "main.h"
#include "wire.h"

static I2C_HandleTypeDef i2c;
static uint64_t last_poll;
static uint8_t initialized;
#define MPU_ADDRESS (0x68U<<1)
static int read_reg(uint8_t reg, uint8_t *p, uint16_t n)
{
    return HAL_I2C_Mem_Read(&i2c,MPU_ADDRESS,reg,I2C_MEMADD_SIZE_8BIT,p,n,2)==HAL_OK;
}
static int write_reg(uint8_t reg, uint8_t value)
{
    return HAL_I2C_Mem_Write(&i2c,MPU_ADDRESS,reg,I2C_MEMADD_SIZE_8BIT,&value,1,2)==HAL_OK;
}
int MPU6050_Init(void)
{
    GPIO_InitTypeDef gpio={0};
    __HAL_RCC_GPIOB_CLK_ENABLE(); __HAL_RCC_I2C1_CLK_ENABLE();
    gpio.Pin=GPIO_PIN_6|GPIO_PIN_7; gpio.Mode=GPIO_MODE_AF_OD;
    gpio.Speed=GPIO_SPEED_FREQ_HIGH; HAL_GPIO_Init(GPIOB,&gpio);
    i2c.Instance=I2C1; i2c.Init.ClockSpeed=400000;
    i2c.Init.DutyCycle=I2C_DUTYCYCLE_2; i2c.Init.AddressingMode=I2C_ADDRESSINGMODE_7BIT;
    i2c.Init.DualAddressMode=I2C_DUALADDRESS_DISABLE; i2c.Init.GeneralCallMode=I2C_GENERALCALL_DISABLE;
    i2c.Init.NoStretchMode=I2C_NOSTRETCH_DISABLE;
    initialized=0;
    if (HAL_I2C_Init(&i2c)!=HAL_OK) return 0;
    uint8_t identity;
    if (!read_reg(0x75,&identity,1) || identity!=0x68 || !write_reg(0x6b,0x80)) return 0;
    HAL_Delay(100);
    /* PLL X gyro, 1 kHz DLPF output /5, +/-2g, +/-250 degrees/s, no FIFO. */
    const uint8_t regs[]={0x6b,0x6c,0x19,0x1a,0x1b,0x1c,0x23,0x6a,0x38};
    const uint8_t values[]={1,0,4,3,0,0,0,0,1};
    for (unsigned j=0;j<sizeof(regs);j++) {
        uint8_t value;
        if (!write_reg(regs[j],values[j]) || !read_reg(regs[j],&value,1) || value!=values[j]) return 0;
    }
    initialized=1; return 1;
}
void MPU6050_Poll(Pose *pose, uint64_t tick)
{
    if (tick-last_poll<1000) return;
    last_poll=tick;
    if (!initialized) { pose->sensor_valid=0; return; }
    uint8_t status, bytes[14];
    if (!read_reg(0x3a,&status,1)) { wire_count(&pose->i2c_errors); pose->sensor_valid=0; return; }
    if (!(status&1)) return;
    if (!read_reg(0x3b,bytes,14)) { wire_count(&pose->i2c_errors); pose->sensor_valid=0; return; }
    int16_t words[7];
    for (unsigned i=0;i<7;i++) words[i]=(int16_t)((uint16_t)bytes[2*i]<<8|bytes[2*i+1]);
    /* Timestamp is a bounded polling approximation, never the transmit time. */
    pose_sample(pose,words,words+4,words[3],tick);
}
