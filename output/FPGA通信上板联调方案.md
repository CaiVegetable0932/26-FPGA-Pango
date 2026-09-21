# FPGA 通信上板联调方案（2026-09-22）

## 范围与身份

本阶段是 `codex/fpga-mcu-praw-protocol` 的独立 **通信联调候选**，不是摄像头 RAW8/ISP/HDMI 完整系统。
工程为 `fpga/project/mini_comms_bringup/mini_comms_bringup.pds`，PG2L100H / FBG676 / -6。
原有真实摄像头 HDMI 镜像及 main 不变。新工程不实例化摄像头、DDR 或 HDMI；若后续烧入此候选，不能同时期待原镜像的 HDMI 画面。

MCU 扩展针脚未得到确认，不能推断成已接线。本候选只把 MINI 板载 CP2102 的 B24（FPGA RX）、C24（FPGA TX）作为 PC 模拟 MCU 的协议联调入口；不能把它说成真实 MCU 接线验证。真实 MCU 固件适配、共地及 3.3 V 电平核对另行完成。

## 上电和发送门槛

1. 125 MHz 差分晶振 N3/N2 → PDS 原生 GPLL → 125 MHz 控制和发送逻辑；异步复位、同步释放。
2. PHY 复位低至少 10 ms，再等待至少 30 ms。Clause-22 全前导码，MDC 半周期 504 ns，输入两级同步，MDIO 在高电平末端采样，覆盖最大 300 ns 数据输出延迟。
3. PHY 地址 1（MINI 例程依据），检查 ID `001C:C91x`；不匹配禁止发送，不广播写 PHY。
4. 本板级候选的 RGMII TXC 与数据使用同一 FPGA 时钟。通过 D08:11 bit8 **使能 PHY TXID** 并完整回读核对；FPGA 不再附加 90°。原通信组件仍支持另一种“FPGA +90°、PHY TXID 关闭”的明确配置，两者不能叠加。
5. 只协商 1000/full，不宣告 10/100、PAUSE、EEE；EEE 广告清零并回读。每 100 ms 检查链路。MDIO/ID/回读错误锁存故障，重置前不恢复发送。
6. 未经串口显式配置不发送 UDP。没有 ARP、ICMP、DHCP 或网络接收；不能用 ping 失败判定此 TX-only 候选失败。
7. 链路失效停止新帧准入；已准入帧继续排空。链路断开时可能丢失整个或部分帧，PC 必须丢弃不完整帧，不能补黑冒充完整视频。

## 专用启动配置命令（仅联调入口）

使用已有 `55 AA / version=1 / cmd / seq LE16 / length LE16 / payload / CRC16 LE` 封装。
CRC16/CCITT-FALSE 覆盖 version 至 payload，参数不变。启动网关识别 `cmd=0x70`、长度 32：

| 字节偏移 | 字段 | 编码 |
| --- | --- | --- |
| 0 | 本次启动 epoch | 非零 LE64，重启必须重新生成，不可重复使用旧命令 |
| 8 | FPGA 源 MAC | 6 字节线上顺序，单播 |
| 14 | PC 目的 MAC | 6 字节线上顺序，明确的单播地址 |
| 20 | FPGA IPv4 | 4 字节网络顺序 |
| 24 | PC IPv4 | 4 字节网络顺序 |
| 28 | FPGA UDP 端口 | 非零 LE16 |
| 30 | PC UDP 端口 | 非零 LE16，默认工具参数 50000 |

回应固定 32 字节，cmd 为 `0x80`/`0x81`，seq 回显。payload[0] 为原协议错误码、[1] 为请求命令；[4..11] 回显 epoch，[20..23] 为 ASCII `TEST`，其余保留零。启动 ACK 不是普通 MCU CAPS 回应。
回应最后停止位及至少额外 24 bit 时间保护结束后，UART 交给原 MCU 协议端点；配置锁定至复位。再执行 CAPS/OPEN/STATUS/ENVIRONMENT 可检验 FPGA MCU 端点，但 PC 发起的环境数据仍是模拟输入。
对重新发送启动命令的 ACK 丢失情况，先尝试原 MCU CAPS 判断是否已切换；不允许悄悄改变运行中的 epoch 或网络目的地。恢复/停止方式为复位，不支持运行中重配置。

`fpga/scripts/prepare_comms_boot.py` 只在本地生成 hex/JSON，不打开串口/网络、不更改网卡设置。要求显式 `--acknowledge-synthetic` 和所有地址。每次调用产生新随机 64-bit epoch；存在理论随机碰撞概率，不作为持久设备身份。下发命令必须使用本次生成值，不重放旧启动配置。

## 测试视频及验收边界

固定 1920×1080 RAW8 形状、30 fps 准入预算；棋盘/水平灰度随 frame_id 移动。它只是字节压力测试，不是真实 Bayer 传感器数据。`descriptor_id=0x54534554 (TEST)`、param_version=0，元数据必须标记 synthetic。保持 PRAW V1 的 64 字节头、1400 字节分片、精确 200 字节尾片，共 1482 包。

不修改正式 host 协议；现有解码器用于离线互通核对。任何以此测试流生成的预览、吞吐或图像测评分数，均不得归入摄像头/ISP/矫正验收。S0、S1、S2/S3 的真实源身份及同帧配对约定不变。

## 时序预算与实板检查

RGMII 按 PHY 内部 2 ns 延迟建模，保留接收端 1 ns setup/hold，另加 0.25 ns PCB 差分偏斜和 0.20 ns PHY 延迟预算，时钟不确定度额外 0.10 ns（工具自身不确定度亦保留）。这些是设计预算，非示波器测量。
UART/MDIO 仅放开外部引脚至首级同步触发器；内部第二级及复位释放保持计时。慢速输出用最大/最小路径延迟限制；工具仍可能报告没有同步 I/O delay 的诊断，需在报告中列明，不冒充所有物理 I/O 已验证。

后续上板顺序：核对器件、镜像哈希和恢复镜像 → Flash 写入与回读校验 → 完全断电重启 → 只读 PHY/串口状态 → 显式配置单播地址 → 网络完整帧率/CRC/丢包检查 → 真实 MCU 接线测试。
本轮只构建、仿真、静态分析、离线格式转换和云端备份，不执行上述硬件步骤。

## 依据

- 只读 MINI V1.3 硬件手册第 13、29、30 页，网口/串口图与针脚表；只读 MINI 网口/MDIO 例程（例程的 200H 工程不能直接冒充 100H 目标）。
- 安装版 PDS 2022.2-SP6.4 `doc/User_Constraint_Editor_User_Guide.pdf`、`Timing_Analyzer_User_Guide.pdf`、`IP_Compiler_User_Guide.pdf`、`Fabric_Configuration_User_Guide.pdf`。
- 安装版 PLL IP UG041001 V1.5 §2.4.1 及原生生成器，相位和频率不靠其他平台推断。
- [Realtek RTL8211F 原厂数据手册（公开镜像）](https://www.boardcon.com/download/RTL8211F-CG-Realtek.pdf)，复位、Clause-22、MMD/EEE、PHYSR 及 I/O 时序。
- [Linux Realtek 原始驱动](https://github.com/torvalds/linux/blob/master/drivers/net/phy/realtek/realtek_main.c)，D08:11 bit8 的 TX 延迟定义。仅参考寄存器含义，不复制驱动代码。

实际运行结果以 `fpga/reports/comms_board_candidate_20260922.md` 为准；本方案本身不代表仿真、时序或硬件已通过。
