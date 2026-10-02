# 二维云台 MCU 验证程序

本目录是 STM32F103C8T6 的双总线舵机验证固件。USART3 连接半双工舵机总线，USART1 连接上位机。上电后自动核对总线 ID1 和 ID2；两只舵机应答无报警后才显示 `READY`，启动核对不写 ID、不移动舵机。

## 快速使用

1. 按 [接线对照表](接线对照表.md) 连接两个串口、半双工转接板、舵机电源和共地。
2. 本次实测 ID1 和 ID2 均可应答；之后上电会自动检查。只有在恢复出厂或地址改变后，才需单独处理 ID 设置。
3. 用 USB-TTL 串口终端打开 USART1，参数为 115200 8N1。
4. 等待 `READY pitch=axis1/id1 yaw=axis2/id2`。
5. `move 1` 控制 pitch（ID1），`move 2` 控制 yaw（ID2），保留约10°往返验证。手动标定位置时使用带角度参数的相对微调，例如 `move 1 0.1` 或 `move 1 -0.1`；用 `get 1` 读取 pitch 当前原始位置，yaw 对应使用 `move 2 ±角度` 和 `get 2`。

命令编号保持不变：pitch 仍为轴1/舵机ID1，yaw 仍为轴2/舵机ID2。上电会读取 ID 寄存器分别核验两个预设地址和状态字；如果任一地址无响应或有报警，显示 `NOT READY`，修复电源/地址后发送 `ready` 重试。程序不在启动时自动更改舵机 EEPROM 地址。

命令处理是单行、单 pending 缓冲。一次命令收到响应后再发送下一条；`scan` 会同步等待舵机响应，扫描全地址最长约 27 秒。

## 角度和标定

协议只定义 0..4095 原始位置。带角度的 `move AXIS DEG` 是从当前位置发出的相对微调，正数增加原始位置，负数减少原始位置；安装方向决定实际物理转向。角度暂按 270° 名义行程换算，每个原始计数约为 `0.066°`；`0.1°` 约为 1.52 个计数，固件取整为 2 个计数（名义约 `0.132°`），小于约 `0.033°` 的输入会舍入为0并报错。实际机械极限与角度映射尚未标定；微调后可用 `get ID` 读取当前位置原始计数。不要把断电后的手动摆位当作保留位置；该型号上电后会回到断电前的位置。使用方法和限制见 [改进记录](reports/改进记录.md)。

## 工程操作

在 PowerShell 中执行：

```powershell
Set-Location C:\Users\ROG\Desktop\工作\FPGA工作空间\26-FPGA-Pango\mcu\yuntai
.\scripts\regenerate.ps1
.\scripts\build.ps1 -Configuration Debug
.\scripts\build.ps1 -Configuration Release
.\scripts\test.ps1
```

`regenerate.ps1` 会根据 `yuntai.ioc` 调用 CubeMX 重新生成配置文件；不要直接编辑 CubeMX 生成区来改变串口配置。构建输出位于 `build/Debug` 或 `build/Release`，可烧录文件为 `yuntai.hex` 和 `yuntai.bin`。

## 当前验证边界

已完成代码级串口解析、命令状态机和限制条件的主机模拟测试，以及 STM32 Debug/Release 固件编译检查。尚未在本轮自动化环境中替代真实硬件验证舵机电源、电平、转接板收发方向和机械角度；烧录后仍需观察 `READY`、`ping`、`get`、`move` 的实际回显。
