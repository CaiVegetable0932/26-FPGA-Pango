# 二维云台 MCU 正式驱动

本固件运行在 STM32F103C8T6 上：USART3 连接两只共用总线的炬晖总线舵机，USART1 连接上位机。舵机编号固定为 pitch=ID1、yaw=ID2。

## 上位机命令

串口参数：115200，8N1，发送命令后回车。

| 命令 | 作用 |
|---|---|
| `ready` | 核验ID和报警状态，把两轴移动到正对角度 |
| `go a1 a2` | 以正对位置为零点，分别将 pitch、yaw 移动到相对角度 a1°、a2°；范围均为 -60°..+60° |
| `get` | 返回两个舵机的当前角度和raw位置 |

固件只接受上述三个命令。`go` 的两个参数是相对正对位置的角度，正对位置为 `0 0`：

```text
ready
go 0 0
get
```

## 标定参数

旧版 get 用 360°/4095 显示角度，因此当时手动对正的 165.4°、211.4°分别对应原始计数 1881、2405；两项一位小数读数各自只对应一个整数 raw 值。改用 270°刻度后，名义角度分别为 124.022°、158.571°。

| 轴 | ID | 正对角度 | 对应raw | 软件允许范围 |
|---|---:|---:|---:|---:|
| pitch | 1 | 124.022° | 1881 | 64.022°..184.022° |
| yaw | 2 | 158.571° | 2405 | 98.571°..218.571° |

回正直接下发已测得的 raw 1881、2405。`go` 的目标 raw 按 `centerRaw + round(offset / 270 × 4095)` 换算，其中两个 offset 必须在 -60°..+60°。

ready 仅读取并检查现有软限位是否覆盖两轴各自的正对角度 ±60°；不再自动写入 EEPROM。如果设备限位不足，返回需要的 raw 范围并拒绝回正。

## 运行行为

- 上电只输出启动提示，不主动移动。
- 发送 `ready` 后，两个舵机同时发送正对目标；完成后分别输出“回正完成”。
- `go` 会先检查两个相对角度范围，再同时发送两个位置目标。运动过程中再次发送命令会被拒绝。
- `get` 返回按270°换算的当前绝对角度、相对正对角度以及 raw 计数。
- 如果舵机曾被旧版本留在电机模式，`ready` 或 `go` 会先发送停止帧并恢复位置模式。

## 接线

详见 [接线对照表](接线对照表.md)。舵机电源必须使用独立、稳定的外部电源，STM32、USB-TTL、转接板和舵机电源必须共地。

## 构建

```powershell
Set-Location C:\Users\ROG\Desktop\工作\FPGA工作空间\26-FPGA-Pango\mcu
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1 -Board f1 -Configuration Release
```

Release 烧录文件为 `../../build/f1/Release/yuntai.hex` 和 `../../build/f1/Release/yuntai.bin`。

`f1_link.c` owns the F4 proxy link on USART1 and `mpu6050.c` owns I2C1. The
existing JOHO USART3 driver and `ready/go/get` behavior remain the motion
authority. A normal `go` is rejected until feedback-confirmed `ready`, five
seconds of stable MPU data and zero calibration are complete. The MPU is a
six-axis relative attitude source; hardware attitude and polarity still need
bench calibration.

`yuntai.ioc` 已同步 I2C1、64MHz 时钟和 F4 代理口 460800 配置；本轮尚未运行 CubeMX 再生成验证。
