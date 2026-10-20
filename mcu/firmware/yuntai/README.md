# 二维云台 F1 固件

本固件运行在 STM32F103C8T6（64 MHz，HSI×16）上，是 MCU 姿态链路的设备端：**PC → F4 → F1**。
F1 不直接连接 PC；USART1 上只有 F4 代理的二进制帧，没有文本命令行。

舵机编号固定：ID1 = pitch，ID2 = yaw，两只共用 USART3 半双工总线。

## 端口分工

| 端口 | 引脚 | 参数 | 对端 |
|---|---|---|---|
| USART1 | PA9 / PA10 | 460800，8N1 | F4 代理（CRC 信封帧，见下） |
| USART3 | PB10 / PB11 | 115200，8N1 | 两只 JOHO 总线舵机，经半双工转换板 |
| I2C1 | PB6 / PB7 | — | **本版不使用**：不接 MPU6050（见下节） |

## 姿态来源（2026-10-20 起）

pitch/yaw 直接由两只舵机的角度反馈换算：`raw` 相对正对中心的偏移，按 270°/4095 折算成 mdeg。**不再使用 MPU6050 姿态融合**——固件不初始化 I2C1、不做六轴融合、不做陀螺零偏标定。

- `Core/Src/mpu6050.c`、`Core/Inc/mpu6050.h` 与其宿主机测试 `tests/test_mpu6050.c` 保留，但**不参与固件构建**（`CMakeLists.txt` 已移除，I2C1 HAL 也不再编译）；恢复步骤见 `mpu6050.h` 顶部注释。
- 对外报文布局**不变**：`F1_STATE` 里 IMU 相关字段恒 0，`sample_seq` 改为舵机反馈采样计数，F4/FPGA 侧解码不需要改偏移。
- 好处：省掉 1 kHz 阻塞式 I2C 采样（原先约 0.4 ms/次），主循环留给舵机总线和状态发送的余量变大。

## 与人机串口的关系（重要）

早期版本在 USART1 上提供 `ready` / `go a1 a2` / `get` 三条文本命令。**该控制台已停用**：USART1 已交给 F4 代理链路，`main.c` 不再调用 `Host_Console_Init()`，`HAL_UART_RxCpltCallback()` 也只把非舵机口分派给 `F1_Link_Rx()`。

后果需要知道：

- `Gimbal_Test_Poll()` 里的 `Host_Console_ReadLine()` 永远拿不到输入，`Command()` 是死路径；
- `gimbal_test.c` 里的 `Reply(...)` 文本（含启动横幅、`[回正完成]`、`[未到位]` 等）因为 `g_hostUart == NULL` 被**静默丢弃**；
- 排障只能读 `F1_STATE` 的字段（`phase`、`zero_valid`、`servo_valid`、`source`、`i2c_errors` 等）。

`host_console.*` 与 `tests/f1/test_console.c` 保留为可独立测试的模块；若要重新获得人读串口，需另占一个空闲口（例如 USART2 的 PA2/PA3）并同时改接线与回调分派，目前**未实现**。

## F4 代理帧

帧格式为 `wire.h` 的 CRC 信封；命令与状态字在 `firmware/common/internal.h`。除 `F1_INFO` 外，每条命令的载荷前 8 字节必须是本次启动的 boot id。

| 命令 | 方向 | 载荷 | 语义 |
|---|---|---|---|
| `0x20` F1_INFO | F4 → F1 | 空 | 探活；回复 boot id |
| `0x21` F1_READY | F4 → F1 | boot（8 B） | 核验 ID/报警/软限位并回正到正对角度 |
| `0x22` F1_GO | F4 → F1 | boot + pitch mdeg + yaw mdeg（各 32 位有符号） | 相对正对运动，两轴均在 ±60.000° |
| `0x24` F1_ZERO | F4 → F1 | boot（8 B） | 回正到位后确认零位，并采集 5 s 稳定数据做标定 |
| `0xa0` F1_REPLY | F1 → F4 | boot + cmd + result | 命令回执 |
| `0xa1` F1_STATE | F1 → F4 | 128 B | 状态帧，5 ms 组帧，发送间隔不小于 7.5 ms |

`result` 码：

| 码 | 含义 |
|---:|---|
| 0 | 成功 |
| 1 | 已接受（回正或标定已开始） |
| 2 | 忙（运动中，或已有待执行命令） |
| 3 | 待执行命令载荷超长 |
| 5 | boot id 不匹配 |
| 6 | 未知命令或长度不符 |
| 7 | 未回正 / 未标定，或回正位置超出容差 |
| 8 | 同序号但内容不同 |
| 9 | 执行失败（舵机通信、限位或模式恢复失败） |
| 10 | 序号过期或重复 |

序号按升序推进，重复序号由 16 条回执缓存去重并重发原结果。`F1_STATE` 的字段布局见 `internal.h` 注释与 `f1_link.c` 的 `publish_state()`。跨端权威说明在 `output/MCU_POSE_V2接口实现补充.md`，不在本目录。

`F1_STATE` 里本版恒为 0 的字段：`imu_capture_us`、accel/gyro/温度、陀螺零偏、`zero_pitch`/`zero_yaw`；`sample_seq` 是舵机反馈采样计数，`source` 在零位有效后恒为 1（纯舵机）。

## 标定参数

旧版 `get` 用 360°/4095 显示角度，当时手动对正的 165.4°、211.4° 分别对应原始计数 1881、2405；改用 270° 刻度后名义角度分别为 124.022°、158.571°。

| 轴 | ID | 正对角度 | 对应 raw | 软件允许范围 |
|---|---:|---:|---:|---:|
| pitch | 1 | 124.022° | 1881 | 64.022°..184.022° |
| yaw | 2 | 158.571° | 2405 | 98.571°..218.571° |

回正直接下发已测得的 raw 1881、2405。`F1_GO` 的目标 raw 按 `centerRaw + round(offset / 270 × 4095)` 换算。`F1_READY` 只读取并校验设备现有软限位是否覆盖各轴正对角度 ±60°，不再写 EEPROM；限位不足时回 `result=9` 并拒绝回正。

> 这组数字目前写在三处：`gimbal_test.h` 的 `GIMBAL_CENTER_*_RAW`、`common/pose.c` 的 `center[2]`、`f1_link.c` 的 `F1_ZERO` 容差判定。改标定必须三处同时改。

## 运行行为

- 上电只初始化，不主动移动；不发送 `F1_READY` 就不会回正。
- `F1_READY` 通过 ID/报警/限位核验后才开始回正；回正完成后两轴到位确认，`F1_STATE` 的 `home_confirmed` 置位，随后进入 5 s 稳定采集。
- 稳定条件（纯舵机）：两轴反馈都在 20 ms 内新鲜，且 `raw` 相对正对中心保持在 ±12 内，连续 **5 s**；任一轴越界或反馈中断则重新计时。
- 标定完成后 `zero_valid` 置位，才允许 `F1_GO`；`F1_GO` 额外要求系统空闲且无故障。
- 运动中每 1 s 必须有 F4 报文（`F1_INFO` 即可）续租，否则本地取消运动并置故障；回正超过 15 s 未完成同样取消。故障态 `phase=5` 保持，直到再次收到 `F1_READY` 并核验通过。
- 若舵机曾被旧版本留在电机模式，`F1_READY` / `F1_GO` 会先发停止帧并切回位置模式。
- 本版没有 IMU：姿态只由舵机反馈决定，因此"回正 + 5 s 居中"是 `zero_valid` 的唯一来源，也不需要安装方向/轴极性标定。台架若发现舵机反馈抖动导致反复重置窗口，先查舵机总线与报警，而不是调滤波参数。

## 资源占用

2026-10-20 用 Release 等价参数（`-Os -g0`）独立重建的结果：

| 项 | 用量 |
|---|---|
| RAM | 14912 / 20480 B（72.8%） |
| FLASH | 28356 / 63488 B（44.7%） |

RAM 里 `BoardPort` 约占 6.4 KB，其中 `rx_tick[512]` 一个数组就 4 KB（为 512 B 接收环逐字节记时间戳）。余量 5.4 KB 要覆盖栈（链接脚本最小 1 KB）与后续功能，扩展前先看这里。

## 接线

详见 [接线对照表](接线对照表.md)。舵机电源必须使用独立、稳定的外部电源；F1、F4、USB-TTL、半双工转换板、MPU 与舵机电源必须共地。

## 构建

```powershell
Set-Location C:\Users\ROG\Desktop\工作\FPGA工作空间\26-FPGA-Pango\mcu
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1 -Board yuntai -Configuration Release
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1
```

工具链取自 STM32Cube bundle（`%LOCALAPPDATA%\stm32cube\bundles`），不要求系统 PATH 里有 `arm-none-eabi-*`。Release 产物为 `../../build/f1/Release/yuntai.hex`、`yuntai.bin`，同目录 `manifest.json` 记录配置与产物的 SHA-256。

与本工程相关的单元测试是 `tests/f1/test_gimbal.c`、`test_console.c`、`test_protocol.c`，均为宿主机桩测试，不覆盖真实总线时序与硬件行为。

## 未验证

- 没有上板记录：舵机 ID/限位/回正、I2C 波形（本版不用）、460800 误码都是设计值，不是实测值。
- `yuntai.ioc` 仍记录 I2C1，但本版不再初始化它，也没有 `MX_I2C1_Init()`；若将来恢复 MPU，需重新生成或手写该初始化，并与 `mpu6050.c` 的 GPIO/I2C 配置对齐。
- `release/` 目录为空；可用固件在 `build/f1/Release`（2026-10-11 版本，早于本次改动）。
